import Foundation

/// `mdock arch-check [run options] IMAGE [-- COMMAND...]`: runs an image's linux/arm64 and
/// linux/amd64 variants side by side (amd64 through Rosetta, or FEX on the GPU engine), so passing on the Mac also says
/// something about an x86 production host. It compares what each architecture actually ships (OS and
/// Python packages) and, with a command, the exit status, output and time. Exit status 1 when the
/// command behaves differently.
enum ArchCheck {
    static let platforms = ["linux/arm64", "linux/amd64"]

    /// Lists OS packages (dpkg, apk or rpm) and pip packages, one "kind name version" per line.
    static let inventory = #"""
        { if command -v dpkg-query >/dev/null 2>&1; then dpkg-query -W -f='os ${Package} ${Version}\n'
          elif command -v apk >/dev/null 2>&1; then apk info -v 2>/dev/null | sed -E 's/^(.+)-([0-9][^-]*-r[0-9]+)$/os \1 \2/'
          elif command -v rpm >/dev/null 2>&1; then rpm -qa --qf 'os %{NAME} %{VERSION}-%{RELEASE}\n'; fi
          for py in python3 python; do
            if command -v $py >/dev/null 2>&1; then $py -m pip list --format=freeze 2>/dev/null | sed -E 's/^([^=]+)==(.*)$/py \1 \2/'; break; fi
          done; } 2>/dev/null
        """#

    struct RunResult {
        var status: Int32
        var stdout: String
        var stderr: String
        var seconds: Double
    }

    static func command(_ args: [String]) throws {
        guard let docker = which("docker") else { throw CommandError(description: "docker CLI not found") }
        // [run options] IMAGE [-- COMMAND...]
        let split = args.firstIndex(of: "--")
        let head = Array(args[..<(split ?? args.count)])
        let userCommand = split.map { Array(args[($0 + 1)...]) } ?? []
        var options: [String] = []
        var image: String?
        var i = 0
        let valued: Set = ["-v", "--volume", "-e", "--env", "-w", "--workdir", "--env-file", "--network", "-u", "--user", "--entrypoint"]
        while i < head.count {
            let a = head[i]
            if valued.contains(a), i + 1 < head.count {
                options += [a, head[i + 1]]
                i += 2
            } else if a.hasPrefix("-") {
                options.append(a)
                i += 1
            } else {
                image = a
                i += 1
                break
            }
        }
        guard let image else {
            throw CommandError(description: "usage: mdock arch-check [docker run options] IMAGE [-- COMMAND...]")
        }

        let emulator = translatorName((status()?["x86"] as? [String: String])?["amd64"]
            ?? ((status()?["engine"] as? String ?? "").contains("GPU") ? "fex" : "rosetta"))
        print("Checking \(image) on \(platforms.joined(separator: " and ")) (amd64 runs through \(emulator))…")
        var inventories: [String: [String: String]] = [:]
        var results: [String: RunResult] = [:]
        for platform in platforms {
            // Pull this platform explicitly: an image that lacks it fails here, with docker's message.
            let pull = runCapture(docker, ["--context", "mdock", "pull", "-q", "--platform", platform, image])
            if pull.status != 0 && !imagePresent(docker, image, platform) {
                print("  \(platform): not available (\(pull.stderr.split(separator: "\n").last ?? ""))")
                continue
            }
            let inv = runCapture(docker, ["--context", "mdock", "run", "--rm", "--platform", platform, "--entrypoint", "sh"]
                                 + options.filter { $0 != "--entrypoint" } + [image, "-c", inventory])
            var packages: [String: String] = [:]
            for line in inv.stdout.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 2)
                if parts.count == 3 { packages["\(parts[0]) \(parts[1])"] = String(parts[2]) }
            }
            inventories[platform] = packages
            if !userCommand.isEmpty {
                let r = runCapture(docker, ["--context", "mdock", "run", "--rm", "--platform", platform] + options + [image] + userCommand)
                results[platform] = r
                print("  \(platform): exit \(r.status) in \(String(format: "%.1f", r.seconds))s, \(packages.count) packages")
            } else {
                print("  \(platform): \(packages.count) packages")
            }
        }
        guard inventories.count == 2, let arm = inventories["linux/arm64"], let x86 = inventories["linux/amd64"] else {
            print("Only one architecture is available, so there is nothing to compare. Build both with:")
            print("  docker buildx build --platform linux/arm64,linux/amd64 --load -t \(image) .")
            exit(1)
        }

        // What each architecture ships.
        let onlyArm = arm.keys.filter { x86[$0] == nil }.sorted()
        let onlyX86 = x86.keys.filter { arm[$0] == nil }.sorted()
        let versions = arm.keys.filter { x86[$0] != nil && x86[$0] != arm[$0] }.sorted()
        let same = arm.keys.count - onlyArm.count - versions.count
        print("Packages: \(same) identical, \(versions.count) at different versions, \(onlyArm.count) only on arm64, \(onlyX86.count) only on amd64")
        for k in versions { print("  version  \(k): arm64 \(arm[k]!)  amd64 \(x86[k]!)") }
        for k in onlyArm { print("  arm64    \(k) \(arm[k]!)") }
        for k in onlyX86 { print("  amd64    \(k) \(x86[k]!)") }

        guard let a = results["linux/arm64"], let b = results["linux/amd64"] else { return }
        var differs = false
        if a.status != b.status {
            differs = true
            print("Command: DIFFERENT exit status (arm64 \(a.status), amd64 \(b.status))")
        }
        if a.stdout != b.stdout {
            differs = true
            print("Command: DIFFERENT output on stdout")
            printDiff(a.stdout, b.stdout)
        }
        if !differs { print("Command: same exit status (\(a.status)) and output on both architectures") }
        exit(differs ? 1 : 0)
    }

    static func imagePresent(_ docker: String, _ image: String, _ platform: String) -> Bool {
        runCapture(docker, ["--context", "mdock", "image", "inspect", "--platform", platform, image]).status == 0
    }

    static func printDiff(_ a: String, _ b: String) {
        let left = a.split(separator: "\n", omittingEmptySubsequences: false)
        let right = b.split(separator: "\n", omittingEmptySubsequences: false)
        var shown = 0
        for n in 0..<max(left.count, right.count) where shown < 10 {
            let l = n < left.count ? String(left[n]) : "<missing>"
            let r = n < right.count ? String(right[n]) : "<missing>"
            if l != r {
                print("  line \(n + 1): arm64 \(l.prefix(100))")
                print("  line \(n + 1): amd64 \(r.prefix(100))")
                shown += 1
            }
        }
    }

    static func runCapture(_ tool: String, _ args: [String]) -> RunResult {
        let start = Date()
        let out = MCPServer.exec(tool, args, timeout: 1800)
        return RunResult(status: out.status, stdout: out.stdout, stderr: out.stderr, seconds: Date().timeIntervalSince(start))
    }
}
