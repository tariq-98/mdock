import Foundation

/// `mdock port IMAGE [--tag NAME] [--replace]`: rebuilds an amd64-only image as a native linux/arm64
/// image by replaying its own build. The amd64 image's history records every step: its distro base,
/// each RUN command (with the build arguments it used) and, as layers, the files each COPY/ADD put in.
/// The port starts from the arm64 variant of the same base (an exactly matching official runtime
/// image when its layers match, otherwise the same distro release), re-runs each RUN natively with
/// architecture names translated (TARGETARCH, x86_64/amd64 download URLs), and adds the copied files
/// as they were. Binaries that came prebuilt from elsewhere (a multi-stage builder, a vendor tarball)
/// stay x86; the report lists them, and Rosetta runs them inside the otherwise native image.
enum Port {
    struct Step {
        var instruction: String
        var empty: Bool
    }

    static func command(_ args: [String]) throws {
        guard let docker = which("docker") else { throw CommandError(description: "docker CLI not found") }
        let words = args.filter { !$0.hasPrefix("--") }
        guard let image = words.first else {
            throw CommandError(description: "usage: mdock port IMAGE [--tag=NAME] [--replace]")
        }
        let replace = args.contains("--replace")
        let tag = args.first { $0.hasPrefix("--tag=") }.map { String($0.dropFirst(6)) }
            ?? (replace ? image : defaultTag(image))
        func dockerRun(_ a: [String], timeout: TimeInterval = 1800) -> MCPServer.Output {
            MCPServer.exec(docker, ["--context", "mdock"] + a, timeout: timeout)
        }

        if dockerRun(["image", "inspect", "--platform", "linux/arm64", image]).status == 0
            || dockerRun(["manifest", "inspect", image]).stdout.contains("\"arm64\"") {
            print("\(image) already has a linux/arm64 variant: docker pull --platform linux/arm64 \(image)")
            return
        }
        print("Porting \(image) to linux/arm64…")
        guard dockerRun(["pull", "-q", "--platform", "linux/amd64", image]).status == 0
            || dockerRun(["image", "inspect", "--platform", "linux/amd64", image]).status == 0 else {
            throw CommandError(description: "can't get the linux/amd64 image \(image)")
        }

        // The image as an OCI layout: config (history, layers) and the layer blobs.
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("mdock-port-\(UUID().uuidString.prefix(8))")
        let context = work.appendingPathComponent("context")
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent("image.tar")
        let saved = dockerRun(["save", "--platform", "linux/amd64", "-o", archive.path, image])
        guard saved.status == 0 else { throw CommandError(description: "docker save failed: \(saved.stderr)") }
        let layout = work.appendingPathComponent("layout")
        try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
        try run("/usr/bin/tar", ["-xf", archive.path, "-C", layout.path])
        try? FileManager.default.removeItem(at: archive)
        guard let manifests = try JSONSerialization.jsonObject(with: Data(contentsOf: layout.appendingPathComponent("manifest.json"))) as? [[String: Any]],
              let manifest = manifests.first, let configPath = manifest["Config"] as? String,
              let layerPaths = manifest["Layers"] as? [String],
              let config = try JSONSerialization.jsonObject(with: Data(contentsOf: layout.appendingPathComponent(configPath))) as? [String: Any],
              let history = config["history"] as? [[String: Any]],
              let diffIDs = (config["rootfs"] as? [String: Any])?["diff_ids"] as? [String] else {
            throw CommandError(description: "unexpected image archive layout")
        }
        let steps = history.map { Step(instruction: ($0["created_by"] as? String ?? "").replacingOccurrences(of: " # buildkit", with: ""),
                                       empty: $0["empty_layer"] as? Bool ?? false) }
        guard steps.filter({ !$0.empty }).count == layerPaths.count else {
            throw CommandError(description: "the image's history doesn't line up with its layers; can't replay it")
        }
        let imageConfig = config["config"] as? [String: Any] ?? [:]
        let env = imageConfig["Env"] as? [String] ?? []

        // The base: an official image whose amd64 layers are a prefix of ours, or the distro release.
        let osRelease = dockerRun(["run", "--rm", "--platform", "linux/amd64", "--entrypoint", "cat", image,
                                   "/etc/os-release", "/etc/debian_version", "/etc/alpine-release"], timeout: 120).stdout
        func field(_ k: String) -> String? {
            osRelease.split(separator: "\n").first { $0.hasPrefix(k + "=") }
                .map { String($0.dropFirst(k.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        var base: String?
        var replayFrom = 0  // history index of the first step to replay
        var baseLayers = 0
        for candidate in baseCandidates(env: env, id: field("ID"), version: field("VERSION_ID"), codename: field("VERSION_CODENAME")) {
            let probe = dockerRun(["buildx", "imagetools", "inspect", candidate, "--format", "{{json .Image}}"], timeout: 60)
            guard probe.status == 0,
                  let all = (try? JSONSerialization.jsonObject(with: Data(probe.stdout.utf8))) as? [String: Any],
                  let amd = all["linux/amd64"] as? [String: Any], all["linux/arm64"] != nil,
                  let ids = (amd["rootfs"] as? [String: Any])?["diff_ids"] as? [String],
                  !ids.isEmpty, ids.count <= diffIDs.count, Array(diffIDs.prefix(ids.count)) == ids else { continue }
            base = candidate
            baseLayers = ids.count
            break
        }
        if let base {
            print("  base: \(base) (its amd64 layers match exactly; using its arm64 variant)")
        } else {
            guard let distro = distroBase(id: field("ID"), version: field("VERSION_ID"), osRelease: osRelease) else {
                throw CommandError(description: "unrecognised base (\(field("PRETTY_NAME") ?? "no /etc/os-release")); "
                                   + "run it under Rosetta: docker run --platform linux/amd64 \(image)")
            }
            base = distro
            baseLayers = 1  // the distro's root filesystem layer
            print("  base: \(distro) (same distro release; replaying everything above its root filesystem)")
        }
        // Skip history up to and including the base's last layer, and the base's own trailing metadata.
        var layersSeen = 0
        for (i, step) in steps.enumerated() where !step.empty {
            layersSeen += 1
            if layersSeen == baseLayers { replayFrom = i + 1; break }
        }

        // The Dockerfile.
        var lines = ["# Ported from \(image) (linux/amd64) by mdock port", "FROM --platform=linux/arm64 \(base!)"]
        var layerIndex = baseLayers
        var substitutions = Set<String>()
        var copies = 0, runs = 0
        for step in steps[replayFrom...] {
            let text = step.instruction.trimmingCharacters(in: .whitespaces)
            if step.empty {
                if let line = metadataInstruction(text) { lines.append(line) }
                continue
            }
            defer { layerIndex += 1 }
            if text.hasPrefix("RUN ") {
                let (argv, subs) = runCommand(String(text.dropFirst(4)))
                substitutions.formUnion(subs)
                let json = String(decoding: try JSONSerialization.data(withJSONObject: argv, options: [.withoutEscapingSlashes]), as: UTF8.self)
                lines.append("RUN \(json)")
                runs += 1
            } else {
                // COPY/ADD (or an unknown step): add the files that layer holds, as they were.
                let name = "layer-\(layerIndex).tar"
                try run("/usr/bin/tar", ["-cf", context.appendingPathComponent(name).path, "--exclude", ".wh.*",
                                         "--exclude", "*/.wh.*", "@" + layout.appendingPathComponent(layerPaths[layerIndex]).path])
                lines.append("ADD \(name) /")
                copies += 1
            }
        }
        // The image's final settings are authoritative.
        if let e = imageConfig["Entrypoint"] as? [String] { lines.append("ENTRYPOINT \(jsonArray(e))") }
        if let c = imageConfig["Cmd"] as? [String] { lines.append("CMD \(jsonArray(c))") }
        if let w = imageConfig["WorkingDir"] as? String, !w.isEmpty { lines.append("WORKDIR \(w)") }
        if let u = imageConfig["User"] as? String, !u.isEmpty { lines.append("USER \(u)") }
        try (lines.joined(separator: "\n") + "\n").write(to: context.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
        print("  replaying \(runs) RUN step(s) natively and \(copies) copied layer(s)"
              + (substitutions.isEmpty ? "" : "; translated: \(substitutions.sorted().joined(separator: ", "))"))

        let build = dockerRun(["buildx", "build", "--progress=plain", "--platform", "linux/arm64", "--load", "-t", tag, context.path], timeout: 7200)
        guard build.status == 0 else {
            let tail = (build.stderr + build.stdout).split(separator: "\n").suffix(15).joined(separator: "\n")
            try? FileManager.default.copyItem(at: context.appendingPathComponent("Dockerfile"),
                                               to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Dockerfile.mdock-port"))
            throw CommandError(description: "the arm64 rebuild failed (Dockerfile saved as ./Dockerfile.mdock-port):\n\(tail)\n"
                               + "Run the original under Rosetta instead: docker run --platform linux/amd64 \(image)")
        }

        // What's still x86: ELF files whose e_machine is x86-64 (0x3e).
        let scan = dockerRun(["run", "--rm", "--platform", "linux/arm64", "--entrypoint", "sh", tag, "-c", #"""
            find / -xdev -type f \( -perm -100 -o -name '*.so*' \) -size +1k 2>/dev/null | while read -r f; do
              h=$(od -An -tx1 -N20 "$f" 2>/dev/null | tr -d ' \n')
              # ELF magic, then e_machine (bytes 18-19): 3e 00 = x86-64, b7 00 = aarch64.
              case "$h" in 7f454c46*3e00) echo "x86 $f" ;; 7f454c46*b700) echo "arm $f" ;; esac
            done
            """#], timeout: 600)
        let arm = scan.stdout.split(separator: "\n").filter { $0.hasPrefix("arm ") }.count
        let x86 = scan.stdout.split(separator: "\n").filter { $0.hasPrefix("x86 ") }.map { String($0.dropFirst(4)) }
        print("Built \(tag) for linux/arm64: \(arm) native binaries" + (x86.isEmpty ? ", no x86 left." : ", \(x86.count) still x86 (Rosetta runs them):"))
        x86.prefix(15).forEach { print("  \($0)") }
        if x86.count > 15 { print("  … and \(x86.count - 15) more") }
        print("Try it: mdock arch-check \(tag) -- <command>   (compare with the original: docker run --platform linux/amd64 \(image))")
    }

    static func defaultTag(_ image: String) -> String {
        let name = image.split(separator: "@").first.map(String.init) ?? image
        if let colon = name.lastIndex(of: ":"), !name[colon...].contains("/") {
            return "\(name[..<colon]):\(name[name.index(after: colon)...])-arm64"
        }
        return "\(name):latest-arm64"
    }

    /// Official runtime images implied by the image's environment (PYTHON_VERSION etc.) and distro.
    static func baseCandidates(env: [String], id: String?, version: String?, codename: String?) -> [String] {
        func value(_ k: String) -> String? { env.first { $0.hasPrefix(k + "=") }.map { String($0.dropFirst(k.count + 1)) } }
        let alpine = id == "alpine" ? version.map { "alpine" + $0.split(separator: ".").prefix(2).joined(separator: ".") } : nil
        var c: [String] = []
        func add(_ family: String, _ v: String?) {
            guard let v else { return }
            if let alpine { c += ["\(family):\(v)-\(alpine)", "\(family):\(v)-alpine"] }
            if let codename { c += ["\(family):\(v)-slim-\(codename)", "\(family):\(v)-\(codename)-slim", "\(family):\(v)-\(codename)"] }
            c += ["\(family):\(v)-slim", "\(family):\(v)"]
        }
        add("python", value("PYTHON_VERSION"))
        add("node", value("NODE_VERSION"))
        add("golang", value("GOLANG_VERSION"))
        add("ruby", value("RUBY_VERSION"))
        add("php", value("PHP_VERSION"))
        if let nginx = value("NGINX_VERSION") { c += ["nginx:\(nginx)" + (alpine != nil ? "-alpine" : ""), "nginx:\(nginx)"] }
        if let distro = id, let version {
            c.append("\(distro):\(version)")
            if distro == "debian", let codename { c += ["debian:\(codename)-slim", "debian:\(codename)"] }
        }
        return c
    }

    /// The same distro release for arm64, when no image matches exactly.
    static func distroBase(id: String?, version: String?, osRelease: String) -> String? {
        switch id {
        case "alpine":
            let full = osRelease.split(separator: "\n").last { $0.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil }
            return "alpine:\(full.map(String.init) ?? version ?? "latest")"
        case "debian":
            return version.map { "debian:\($0)-slim" }
        case "ubuntu":
            return version.map { "ubuntu:\($0)" }
        default:
            return nil
        }
    }

    /// Dockerfile line for a metadata-only history step (ENV, WORKDIR, ...); nil to skip it.
    static func metadataInstruction(_ text: String) -> String? {
        let keep = ["ENV ", "WORKDIR ", "USER ", "EXPOSE ", "LABEL ", "SHELL ", "STOPSIGNAL ", "VOLUME "]
        guard let prefix = keep.first(where: { text.hasPrefix($0) }) else { return nil }
        if prefix == "ENV ", let eq = text.firstIndex(of: "=") {
            // History writes ENV KEY=value with the raw value; quote it for the Dockerfile.
            let key = text[text.index(text.startIndex, offsetBy: 4)..<eq]
            let value = String(text[text.index(after: eq)...])
            return "ENV \(key)=\(String(decoding: (try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])) ?? Data(), as: UTF8.self).dropFirst().dropLast())"
        }
        return text
    }

    /// The argv of a recorded RUN ("|2 A=1 B=2 /bin/sh -c cmd" or "/bin/sh -c cmd"), with build
    /// arguments as environment and amd64 names translated to arm64.
    static func runCommand(_ recorded: String) -> ([String], Set<String>) {
        var text = recorded
        var assignments: [String] = []
        if text.hasPrefix("|"), let space = text.firstIndex(of: " "), let n = Int(text[text.index(after: text.startIndex)..<space]) {
            text = String(text[text.index(after: space)...])
            for _ in 0..<n {
                guard let end = text.firstIndex(of: " ") else { break }
                assignments.append(String(text[..<end]))
                text = String(text[text.index(after: end)...])
            }
        }
        var subs = Set<String>()
        func translate(_ s: String) -> String {
            var out = s
            for (from, to) in [("TARGETARCH=amd64", "TARGETARCH=arm64"), ("TARGETPLATFORM=linux/amd64", "TARGETPLATFORM=linux/arm64"),
                               ("BUILDARCH=amd64", "BUILDARCH=arm64"), ("x86_64", "aarch64"), ("linux-amd64", "linux-arm64"),
                               ("linux_amd64", "linux_arm64"), ("linux-x64", "linux-arm64"), ("_amd64.deb", "_arm64.deb"),
                               ("amd64.tar", "arm64.tar"), ("-amd64.", "-arm64.")] where out.contains(from) {
                out = out.replacingOccurrences(of: from, with: to)
                subs.insert("\(from)→\(to)")
            }
            return out
        }
        // Split "SHELL ARGS -c COMMAND".
        var shell = ["/bin/sh", "-c"]
        var command = text
        if let r = text.range(of: " -c ") {
            shell = text[..<r.lowerBound].split(separator: " ").map(String.init) + ["-c"]
            command = String(text[r.upperBound...])
        } else if text.hasPrefix("[") {
            // Exec form: already an argv.
            if let argv = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String] {
                return (argv.map(translate), subs)
            }
        }
        let env = assignments.map(translate)
        return ((env.isEmpty ? [] : ["/usr/bin/env"] + env) + shell + [translate(command)], subs)
    }

    static func jsonArray(_ a: [String]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: a, options: [.withoutEscapingSlashes])) ?? Data("[]".utf8), as: UTF8.self)
    }
}
