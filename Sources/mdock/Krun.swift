import Foundation

/// GPU engine: libkrun on Hypervisor.framework with a Venus virtio-gpu
/// (guest Vulkan -> virglrenderer -> MoltenVK -> Metal). libkrun is loaded with
/// dlopen so the default Virtualization.framework engine never depends on it.
///
/// Process layout: the daemon runs gvproxy (guest networking) and `mdock krun-vmm`,
/// which hands itself to krun_start_enter and becomes the VM. Guest vsock ports
/// surface as unix sockets in ~/.mdock (see socketPath).
enum Krun {
    static let networkSocket = Paths.url("gvproxy-net.sock")
    static let gvproxyLog = Paths.url("gvproxy.log")
    /// gvproxy NATs this address to the Mac's own 127.0.0.1.
    static let hostLoopbackIP = "192.168.127.254"

    static func socketPath(_ port: UInt32) -> String { Paths.url("krun-\(port).sock").path }

    /// Where the from-source GPU stack lives: next to the binary, or the build tree.
    static var prefix: URL? {
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
        var candidates = [exe.deletingLastPathComponent().appendingPathComponent("gpu")]
        if let env = ProcessInfo.processInfo.environment["MDOCK_GPU_PREFIX"] { candidates.insert(URL(fileURLWithPath: env), at: 0) }
        // Running from the build tree: <repo>/.build/<triple>/release/mdock -> <repo>/gpu/prefix
        var dir = exe.deletingLastPathComponent()
        while dir.path != "/" {
            candidates.append(dir.appendingPathComponent("gpu/prefix"))
            dir = dir.deletingLastPathComponent()
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("lib/libkrun.dylib").path) }
    }

    static var gvproxy: String? {
        prefix.map { $0.appendingPathComponent("bin/gvproxy").path }.flatMap {
            FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil
        }
    }

    // MARK: VMM process

    private typealias CreateCtx = @convention(c) () -> Int32
    private typealias CtxOnly = @convention(c) (UInt32) -> Int32
    private typealias SetVMConfig = @convention(c) (UInt32, UInt8, UInt32) -> Int32
    private typealias SetKernel = @convention(c) (UInt32, UnsafePointer<CChar>, UInt32, UnsafePointer<CChar>?, UnsafePointer<CChar>) -> Int32
    private typealias AddDisk2 = @convention(c) (UInt32, UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32, Bool) -> Int32
    private typealias AddVirtiofs = @convention(c) (UInt32, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    private typealias AddNetUnixgram = @convention(c) (UInt32, UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<UInt8>, UInt32, UInt32) -> Int32
    private typealias SetGPUOptions2 = @convention(c) (UInt32, UInt32, UInt64) -> Int32
    private typealias AddVsock = @convention(c) (UInt32, UInt32) -> Int32
    private typealias AddVsockPort2 = @convention(c) (UInt32, UInt32, UnsafePointer<CChar>, Bool) -> Int32
    private typealias SetPath = @convention(c) (UInt32, UnsafePointer<CChar>) -> Int32
    private typealias SetLogLevel = @convention(c) (UInt32) -> Int32

    private static let virglVenus: UInt32 = 1 << 6
    private static let virglNoVirgl: UInt32 = 1 << 7
    private static let netFlagVfkit: UInt32 = 1 << 0
    private static let kernelFormatRaw: UInt32 = 0
    private static let diskFormatRaw: UInt32 = 0

    /// Configures the microVM and turns this process into it. Never returns.
    static func runVMM(config: Config) -> Never {
        func fail(_ message: String) -> Never {
            log("krun: \(message)")
            exit(1)
        }
        // A crash here takes the whole VM down; leave a backtrace in the daemon log (macOS doesn't
        // always write a crash report for it).
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE] {
            signal(sig) { sig in
                let header = "krun-vmm: fatal signal \(sig), backtrace:\n"
                _ = header.withCString { write(STDERR_FILENO, $0, strlen($0)) }
                var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
                let count = backtrace(&frames, Int32(frames.count))
                backtrace_symbols_fd(&frames, count, STDERR_FILENO)
                signal(sig, SIG_DFL)
                raise(sig)
            }
        }
        guard let prefix else { fail("libkrun not found; build it with gpu/build.sh") }
        // Debug hook: ~/.mdock/krun-rust-log holds a RUST_LOG filter for libkrun (e.g. krun_devices::virtio::vsock=debug).
        if let filter = try? String(contentsOf: Paths.url("krun-rust-log"), encoding: .utf8) {
            setenv("RUST_LOG", filter.trimmingCharacters(in: .whitespacesAndNewlines), 1)
        }
        guard let lib = dlopen(prefix.appendingPathComponent("lib/libkrun.dylib").path, RTLD_NOW) else {
            fail(String(cString: dlerror()))
        }
        func fn<T>(_ name: String, _: T.Type) -> T {
            guard let symbol = dlsym(lib, name) else { fail("missing symbol \(name)") }
            return unsafeBitCast(symbol, to: T.self)
        }
        func check(_ rc: Int32, _ what: String) {
            if rc < 0 { fail("\(what) failed: \(String(cString: strerror(-rc)))") }
        }

        _ = fn("krun_set_log_level", SetLogLevel.self)(1)  // errors only
        let ctx = fn("krun_create_ctx", CreateCtx.self)()
        guard ctx >= 0 else { fail("krun_create_ctx: \(ctx)") }
        let id = UInt32(ctx)

        let memMiB = UInt32(config.memoryGiB * 1024)
        check(fn("krun_set_vm_config", SetVMConfig.self)(id, UInt8(min(config.cpus, 255)), memMiB), "set_vm_config")
        let cmdline = "root=/dev/vda2 ro rootwait rootfstype=ext4 modules=ext4,virtio_mmio,virtio_blk console=hvc0 quiet init_on_alloc=0 " +
            "rcupdate.rcu_expedited=1 rcutree.jiffies_till_first_fqs=0 rcutree.jiffies_till_next_fqs=1 mdock.engine=krun"
        let initrd = FileManager.default.fileExists(atPath: Paths.kernelMountsRoot.path) ? nil : Paths.initrd.path
        check(fn("krun_set_kernel", SetKernel.self)(id, Paths.kernel.path, kernelFormatRaw, initrd, cmdline), "set_kernel")

        // Same disks and order as the VZ engine: boot=vda, data=vdb, seed=vdc.
        let addDisk = fn("krun_add_disk2", AddDisk2.self)
        check(addDisk(id, "boot", Paths.bootDisk.path, diskFormatRaw, false), "add boot disk")
        check(addDisk(id, "data", Paths.dataDisk.path, diskFormatRaw, false), "add data disk")
        check(addDisk(id, "seed", Paths.seed.path, diskFormatRaw, true), "add seed disk")

        let addFS = fn("krun_add_virtiofs", AddVirtiofs.self)
        for share in config.shares where FileManager.default.fileExists(atPath: share.host) {
            check(addFS(id, share.tag, share.host), "add virtiofs \(share.tag)")
        }

        var mac = config.mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        if mac.count != 6 { mac = [0x5a, 0x94, 0xef, 0xe4, 0x0c, 0xee] }
        check(fn("krun_add_net_unixgram", AddNetUnixgram.self)(id, networkSocket.path, -1, &mac, 0, netFlagVfkit), "add net")

        // VRAM is a host window, not committed memory; krunkit sizes it the same way:
        // up to host RAM, within the 36-bit IPA space minus guest RAM.
        let roundedGiB = UInt64(memMiB) / 1024 + 1
        let vram = min((63488 - roundedGiB * 1024) << 20, ProcessInfo.processInfo.physicalMemory)
        // krunkit's flags. THREAD_SYNC | USE_ASYNC_FENCE_CB (1<<1 | 1<<8) measured no different
        // on llama.cpp token generation, so the tested default stays; override to experiment.
        var flags = virglVenus | virglNoVirgl
        if let override = ProcessInfo.processInfo.environment["MDOCK_VIRGL_FLAGS"].flatMap({ UInt32($0) }) { flags = override }
        check(fn("krun_set_gpu_options2", SetGPUOptions2.self)(id, flags, vram), "set_gpu_options2")

        // Plain vsock (no TSI socket hijacking: the guest has a real NIC).
        check(fn("krun_disable_implicit_vsock", CtxOnly.self)(id), "disable_implicit_vsock")
        check(fn("krun_add_vsock", AddVsock.self)(id, 0), "add_vsock")
        let addPort = fn("krun_add_vsock_port2", AddVsockPort2.self)
        for port in [Guest.dockerPort, Guest.relayPort, Guest.poweroffPort, Guest.fileEventsPort, Guest.udpPort] {
            unlink(socketPath(port))
            check(addPort(id, port, socketPath(port), true), "vsock port \(port)")
        }
        // Guest -> host: libkrun connects to the daemon's sockets (notifications, accel bridge).
        check(addPort(id, Guest.notifyPort, socketPath(Guest.notifyPort), false), "vsock port \(Guest.notifyPort)")
        for service in Accel.services {
            check(addPort(id, service.port, Accel.krunSocket(service.port), false), "vsock port \(service.port)")
        }

        check(fn("krun_set_console_output", SetPath.self)(id, Paths.console.path), "console")
        log("krun: starting \(config.cpus) vCPUs, \(config.memoryGiB) GiB, Venus GPU with \(vram >> 30) GiB host window")
        let rc = fn("krun_start_enter", CtxOnly.self)(id)
        fail("krun_start_enter returned \(rc)")
    }
}
