import Foundation
import Virtualization

let mdockVersion = "1.1.0"

struct Share: Codable {
    var tag: String
    var host: String
    var guest: String
}

struct Config: Codable {
    var cpus: Int
    var memoryGiB: Int
    var diskGiB: Int
    var mac: String
    var shares: [Share]
    var rosetta: Bool
    /// Rosetta's ahead-of-time cache (rosettad in the guest). Off unless set: Rosetta's translator
    /// crashes on, or miscompiles, some binaries (Node's Alpine builds), and then they can't start.
    var rosettaAOT: Bool?
    var aot: Bool {
        get { rosettaAOT ?? false }
        set { rosettaAOT = newValue }
    }
    var forwardPorts: Bool
    /// Shrink guest RAM via the balloon when idle, returning memory to macOS.
    var autoBalloon: Bool
    /// Boot on libkrun with a Venus GPU instead of Virtualization.framework (optional: older configs lack it).
    var gpuEngine: Bool?
    var gpu: Bool {
        get { gpuEngine ?? false }
        set { gpuEngine = newValue }
    }
    /// "fsync" (safe default), "full" (F_FULLFSYNC, slowest) or "none" (fastest, unsafe on host crash).
    var diskSync: String
    /// Stop the VM after this many idle minutes with nothing running; launchd starts it again on the
    /// next docker command (needs autostart). 0 turns it off; nil means the default (10).
    var idleMinutes: Int?
    var idle: Int { idleMinutes ?? 10 }
    /// Single-node Kubernetes (k3s on Docker) in the VM (optional: older configs lack it).
    var kubernetes: Bool?
    var k8s: Bool {
        get { kubernetes ?? false }
        set { kubernetes = newValue }
    }

    static func defaults() -> Config {
        let hostCPUs = ProcessInfo.processInfo.activeProcessorCount
        let hostGiB = Int(ProcessInfo.processInfo.physicalMemory >> 30)
        return Config(
            cpus: min(hostCPUs, VZVirtualMachineConfiguration.maximumAllowedCPUCount),
            memoryGiB: max(4, hostGiB / 2),
            diskGiB: 128,
            mac: VZMACAddress.randomLocallyAdministered().string,
            shares: [
                Share(tag: "users", host: "/Users", guest: "/Users"),
                Share(tag: "volumes", host: "/Volumes", guest: "/Volumes"),
                Share(tag: "private", host: "/private", guest: "/private"),
                Share(tag: "folders", host: "/private/var/folders", guest: "/var/folders"),
            ],
            rosetta: true,
            forwardPorts: true,
            autoBalloon: true,
            diskSync: "fsync"
        )
    }
}

/// The canonical path with symlinks resolved. Unlike URL.resolvingSymlinksInPath, which drops the
/// /private prefix (/private/tmp/x becomes /tmp/x), it gives the path the VM's shares see.
func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

enum Paths {
    static let state = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mdock")
    static func url(_ name: String) -> URL { state.appendingPathComponent(name) }
    static let config = url("config.json")
    static let bootDisk = url("boot.img")
    static let dataDisk = url("data.img")
    static let seed = url("seed.iso")
    static let kernel = url("vmlinux")
    static let initrd = url("initramfs")
    /// Present when the installed kernel has the virtio disk driver and ext4 built in (mdock's own,
    /// kernel/build.sh): it mounts the root disk itself, so it boots without the initramfs. Delete it
    /// to boot through the initramfs again.
    static let kernelMountsRoot = url("kernel.mounts-root")
    /// mtimes of the guest's kernel+initramfs, as reported by the guest and as last extracted.
    static let guestKernelStamp = url("kernel.guest")
    static let extractedKernelStamp = url("kernel.extracted")
    /// Kernel + initramfs the guest copies out after an upgrade (`mdock upgrade`), with the stamp it
    /// will report for them: used instead of reading the boot disk.
    static let kernelStaging = url("kernel-staging")
    static let machineID = url("machine-id")
    static let console = url("console.log")
    /// The previous boot's console: after the guest crashed and the VM restarted, the reason is here.
    static let previousConsole = url("console.log.1")
    static let daemonLog = url("daemon.log")
    static let dockerSocket = url("docker.sock")
    static let controlSocket = url("control.sock")
    static let pid = url("daemon.pid")
    static let daemonLock = url("daemon.lock")
    /// Supervised start times, for crash-loop detection.
    static let starts = url("starts")
    /// Written by an idle stop (launchd still holds docker.sock); removed when the daemon starts.
    static let idleMarker = url("idle-stopped")
    /// Docker API for mdock's own long-lived clients (Mutagen's sync sessions): served only while the
    /// VM runs and never counted as activity, so a sync session neither blocks nor undoes an idle stop.
    static let internalSocket = url("internal.sock")
    /// Docker Desktop's per-user socket. Its privileged helper keeps /var/run/docker.sock pointing here.
    static let desktopSocket = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".docker/run/docker.sock")
}

/// Moves a log aside once it passes `limit` bytes (one generation kept as `<name>.1`).
/// Returns true if it rotated.
@discardableResult
func rotateLog(_ url: URL, limit: Int = 8 << 20) -> Bool {
    guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit else {
        return false
    }
    let old = URL(fileURLWithPath: url.path + ".1")
    try? FileManager.default.removeItem(at: old)
    return (try? FileManager.default.moveItem(at: url, to: old)) != nil
}

let imageURL = "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/generic_alpine-3.24.1-aarch64-uefi-cloudinit-r0.qcow2"

func loadConfig() throws -> Config {
    try JSONDecoder().decode(Config.self, from: Data(contentsOf: Paths.config))
}

func saveConfig(_ config: Config) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(config).write(to: Paths.config)
}

struct CommandError: Error, CustomStringConvertible {
    var description: String
}

@discardableResult
func run(_ tool: String, _ args: [String], quiet: Bool = false, environment: [String: String] = [:]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    if !environment.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = quiet ? FileHandle.nullDevice : pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CommandError(description: "\(tool) \(args.joined(separator: " ")) failed: \(output)")
    }
    return output
}

/// Copies the guest's current kernel and initramfs out so the VM boots them directly (no firmware,
/// no GRUB). A kernel the guest staged after an upgrade is used as is; otherwise they are read out of
/// the ext4 root, only when the guest has reported a different kernel than the one we have (and on
/// first boot).
func extractKernel() throws {
    let reported = try? String(contentsOf: Paths.guestKernelStamp, encoding: .utf8)
    let extracted = try? String(contentsOf: Paths.extractedKernelStamp, encoding: .utf8)
    let staged = Paths.kernelStaging
    if let stamp = try? String(contentsOf: staged.appendingPathComponent("stamp"), encoding: .utf8) {
        try installKernel(zboot: staged.appendingPathComponent("vmlinuz-virt"), initrd: staged.appendingPathComponent("initramfs-virt"))
        try stamp.write(to: Paths.extractedKernelStamp, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: staged)
        return
    }
    if FileManager.default.fileExists(atPath: Paths.kernel.path), FileManager.default.fileExists(atPath: Paths.initrd.path),
       reported == nil || reported == extracted {
        return
    }
    let debugfs = "/opt/homebrew/opt/e2fsprogs/sbin/debugfs"
    guard FileManager.default.isExecutableFile(atPath: debugfs) else {
        throw CommandError(description: "debugfs is needed to read the guest kernel: brew install e2fsprogs")
    }
    let attach = try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nomount", "-noverify",
                                               "-imagekey", "diskimage-class=CRawDiskImage", Paths.bootDisk.path])
    let lines = attach.split(separator: "\n")
    guard let whole = lines.first?.split(separator: " ").first.map(String.init),
          let root = lines.first(where: { $0.contains("Linux") })?.split(separator: " ").first.map(String.init) else {
        throw CommandError(description: "no Linux partition in boot image: \(attach)")
    }
    defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", whole]) }
    let zboot = Paths.url("vmlinuz.efi"), initrd = Paths.url("initramfs.new")
    defer {
        try? FileManager.default.removeItem(at: zboot)
        try? FileManager.default.removeItem(at: initrd)
    }
    // mdock's own kernel (kernel/build.sh, `mdock kernel install`) when it is installed, else Alpine's.
    let own = ((try? run(debugfs, ["-R", "stat /boot/vmlinuz-mdock", root], quiet: true)) ?? "").contains("Inode:")
    let flavor = own ? "mdock" : "virt"
    try run(debugfs, ["-R", "dump /boot/vmlinuz-\(flavor) \(zboot.path)", root], quiet: true)
    try run(debugfs, ["-R", "dump /boot/initramfs-\(flavor) \(initrd.path)", root], quiet: true)
    try installKernel(zboot: zboot, initrd: initrd)
    if let reported { try? reported.write(to: Paths.extractedKernelStamp, atomically: true, encoding: .utf8) }
}

/// Installs the guest's kernel (arm64 EFI zboot, unpacked to the raw Image VZLinuxBootLoader and
/// libkrun boot) and initramfs. Both are written aside and renamed into place.
func installKernel(zboot: URL, initrd: URL) throws {
    // arm64 EFI zboot: "zimg" at 4, payload offset/size at 8/12, compression name at 24.
    let data = try Data(contentsOf: zboot)
    func u32(_ at: Int) -> Int { data[at..<at + 4].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) } }
    let kernel = URL(fileURLWithPath: Paths.kernel.path + ".new")
    defer { try? FileManager.default.removeItem(at: kernel) }
    if data.count > 64, String(decoding: data[4..<8], as: UTF8.self) == "zimg" {
        let compression = String(decoding: data[24..<32].prefix { $0 != 0 }, as: UTF8.self)
        guard compression == "gzip" else { throw CommandError(description: "unsupported kernel compression \(compression)") }
        let payload = Paths.url("vmlinux.gz")
        try data[u32(8)..<u32(8) + u32(12)].write(to: payload)
        defer { try? FileManager.default.removeItem(at: payload) }
        let gunzip = Process()
        gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gunzip.arguments = ["-dc", payload.path]
        FileManager.default.createFile(atPath: kernel.path, contents: nil)
        gunzip.standardOutput = try FileHandle(forWritingTo: kernel)
        try gunzip.run()
        gunzip.waitUntilExit()
        guard gunzip.terminationStatus == 0 else { throw CommandError(description: "failed to unpack kernel") }
    } else {
        try data.write(to: kernel)  // already a raw Image
    }
    let ramdisk = URL(fileURLWithPath: Paths.initrd.path + ".new")
    try? FileManager.default.removeItem(at: ramdisk)
    try FileManager.default.copyItem(at: initrd, to: ramdisk)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ramdisk.path)
    guard rename(kernel.path, Paths.kernel.path) == 0, rename(ramdisk.path, Paths.initrd.path) == 0 else {
        throw CommandError(description: "installing kernel: \(String(cString: strerror(errno)))")
    }
    // Built-in drivers leave their names in the image; modules keep theirs in the .ko files.
    let image = try Data(contentsOf: Paths.kernel, options: .alwaysMapped)
    if image.range(of: Data("virtio_blk".utf8)) != nil && image.range(of: Data("EXT4-fs".utf8)) != nil {
        FileManager.default.createFile(atPath: Paths.kernelMountsRoot.path, contents: nil)
    } else {
        try? FileManager.default.removeItem(at: Paths.kernelMountsRoot)
    }
}

/// Finds a tool: ~/.local/bin first (where cli/build.sh installs the docker CLI built from source),
/// then $PATH, then the usual Homebrew and system locations.
func which(_ name: String) -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
    for dir in ["\(home)/.local/bin"] + path + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] where dir.hasPrefix("/") {
        let candidate = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}
