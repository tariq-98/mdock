import Foundation

/// `mdock kernel`: mdock's own guest kernel (kernel/build.sh): Alpine's linux-virt configuration plus
/// Asahi Linux's TSO patches. With it, x86 translators (Rosetta on the default engine, FEX on the GPU
/// engine) run translated code in x86's memory order in hardware instead of emulating it with
/// barriers. The guest keeps Alpine's kernel too; `remove` goes back to it.
enum Kernel {
    static func command(_ args: [String]) throws {
        switch args.first {
        case "install": try install(args.count > 1 ? args[1] : nil)
        case "remove": try remove()
        case nil, "status": status(json: args.contains("--json"))
        default: throw CommandError(description: "usage: mdock kernel install [DIR] | remove | status [--json]")
        }
    }

    /// kernel/out in the source tree this binary was built from.
    static var buildOutput: URL? {
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
        // The app ships it in Contents/Resources/kernel; a development build finds kernel/out above itself.
        var candidates = [exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/kernel")]
        var dir = exe.deletingLastPathComponent()
        while dir.path != "/" {
            candidates.append(dir.appendingPathComponent("kernel/out"))
            dir = dir.deletingLastPathComponent()
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Image").path) }
    }

    static func requireRunning() throws {
        guard mdock.status()?["ready"] as? Bool == true else { throw CommandError(description: "mdock is not running") }
    }

    /// Puts the kernel's modules, image and initramfs into the guest (/boot/*-mdock), and stages it
    /// for the Mac, which boots it from the next restart on.
    static func install(_ path: String?) throws {
        try requireRunning()
        guard let dir = path.map({ URL(fileURLWithPath: realPath($0)) }) ?? buildOutput else {
            throw CommandError(description: "no kernel built yet: ~/mdock/kernel/build.sh")
        }
        let release = try String(contentsOf: dir.appendingPathComponent("release"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for file in ["Image", "modules.tar.gz"] where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path) {
            throw CommandError(description: "\(dir.path) has no \(file)")
        }
        print("Installing kernel \(release) in the guest…")
        _ = try guestScript(#"""
            set -e
            dir=$1 release=$2 staging=$3
            tar -xzf "$dir/modules.tar.gz" -C /
            depmod -a "$release"
            cp "$dir/Image" /boot/vmlinuz-mdock.new && mv /boot/vmlinuz-mdock.new /boot/vmlinuz-mdock
            mkinitfs -o /boot/initramfs-mdock "$release" >/dev/null
            rm -rf "$staging" && mkdir -p "$staging"
            cp /boot/vmlinuz-mdock "$staging/vmlinuz-virt"
            cp /boot/initramfs-mdock "$staging/initramfs-virt"
            stat -c %Y /boot/vmlinuz-mdock /boot/initramfs-mdock | tr '\n' '-' > "$staging/stamp"
            sync
            """#, [dir.path, release, Paths.kernelStaging.path])
        print("Kernel \(release) is installed and boots from the next restart: mdock restart")
    }

    /// Back to Alpine's kernel from the next restart. The running kernel's modules stay until then
    /// (the guest drops them at boot).
    static func remove() throws {
        try requireRunning()
        _ = try guestScript(#"""
            set -e
            staging=$1
            rm -f /boot/vmlinuz-mdock /boot/initramfs-mdock
            for d in /lib/modules/*-mdock; do [ -d "$d" ] && [ "$d" != "/lib/modules/$(uname -r)" ] && rm -rf "$d"; done
            rm -rf "$staging" && mkdir -p "$staging"
            cp /boot/vmlinuz-virt "$staging/vmlinuz-virt"
            cp /boot/initramfs-virt "$staging/initramfs-virt"
            stat -c %Y /boot/vmlinuz-virt /boot/initramfs-virt | tr '\n' '-' > "$staging/stamp"
            sync
            """#, [Paths.kernelStaging.path])
        print("Alpine's kernel boots from the next restart: mdock restart")
    }

    static func status(json: Bool) {
        let s = mdock.status()
        let built = buildOutput.flatMap { try? String(contentsOf: $0.appendingPathComponent("release"), encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var info: [String: Any] = ["running": s?["kernel"] as? String ?? NSNull(), "tso": s?["tso"] ?? NSNull(),
                                   "built": built ?? NSNull()]
        if s == nil { info["running"] = NSNull() }
        if json {
            print(String(decoding: (try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])) ?? Data(), as: UTF8.self))
            return
        }
        print("running: \(s?["kernel"] as? String ?? (s == nil ? "VM not running" : "unknown"))")
        switch s?["tso"] as? Bool {
        case true?: print("TSO:     yes: x86 translators run in x86's memory order in hardware")
        case false?: print("TSO:     no: x86 translators emulate x86's memory order (mdock kernel install)")
        default: print("TSO:     unknown")
        }
        print("built:   \(built ?? "none (~/mdock/kernel/build.sh)")")
    }
}
