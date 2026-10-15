import CoreServices
import Foundation
import Virtualization

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("\(stamp) \(message)\n".data(using: .utf8)!)
}

/// Owns the VM and every host-side bridge into it. Runs as `mdock daemon`.
final class Daemon: NSObject, VZVirtualMachineDelegate, VZVirtioSocketListenerDelegate {
    let config: Config
    let queue = DispatchQueue(label: "mdock.vm")
    private var vm: VZVirtualMachine!
    private let notifyListener = VZVirtioSocketListener()
    private let accel = AccelRouter()

    private let stateLock = NSLock()
    private var guestIP: String?
    private var ready = false
    private var startedAt = Date()
    private var readyAt: Date?
    /// Uptime clock (stops while the Mac sleeps, so waking up never looks like a stall).
    private var lastGuestReport = DispatchTime.now().uptimeNanoseconds
    private var bridgeStalled = false
    /// Exit status once the VM is gone: set by stop() (0 = requested, 75 = watchdog restart).
    /// Anything else (crash, guest powered itself off) exits 75 so launchd brings mdock back.
    private var stopStatus: Int32?
    private var exitStatus: Int32 { stateLock.withLock { stopStatus ?? 75 } }
    private var memTotalKiB = 0
    private var memAvailKiB = 0
    private var balloonMiB = 0
    private var shrinkVotes = 0
    private var forwards: [String: Cancel] = [:]
    /// Kubernetes as the guest agent last reported it: off, down, starting or up.
    private var k8sState = "off"
    private var k8sVersion = ""
    private var k8sPorts: [String] = []
    /// Listeners of host-network containers, as the guest agent reports them ("tcp:8080:all").
    private var hostNetPorts: [String] = []
    /// Whether the guest kernel runs x86 translators' threads in x86's memory order (Apple silicon
    /// TSO, mdock's kernel); nil until the guest says.
    private var tso: Bool?
    private var binfmt: [String] = []

    /// The translator the guest registered for each x86 architecture, from its binfmt_misc handler names.
    static func translators(_ handlers: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for handler in handlers {
            switch handler {
            case "rosetta": out["amd64"] = "rosetta"
            case "FEX-x86_64": out["amd64"] = "fex"
            case "qemu-x86_64": out["amd64"] = "qemu"
            case "FEX-x86": out["386"] = "fex"
            case "qemu-i386": out["386"] = "qemu"
            default: break
            }
        }
        return out
    }
    private var kernelRelease = ""

    /// Socket activation (LaunchAgent "Sockets"): launchd holds docker.sock and starts mdock when a
    /// client connects. After `config.idle` minutes with no docker clients and no containers running,
    /// the VM stops and all its memory and CPU go back to macOS.
    private var socketActivated = false
    private var dockerClients = 0
    private var lastDockerUse = DispatchTime.now().uptimeNanoseconds
    /// Running containers other than mdock's own (the sync container); -1 until first counted.
    private var busyContainers = -1
    private var idleStopped = false
    /// The container that last kept the VM from an idle stop (logged once per container).
    private var idleVeto: String?

    /// Published TCP ports reach the guest over the VM's network (DialBack, several GB/s) once the guest
    /// is ready, else over the vsock relay (~0.6 GB/s), which the GPU engine (guest behind gvproxy)
    /// always uses. After a dial-back fails, ports use the relay until `dialBackRetryAt` (uptime).
    private var dialBack: DialBack?
    private var dialBackFailed = false
    private var dialBackRetryAt: UInt64 = 0
    private var dialBackStarting = false

    init(config: Config) {
        self.config = config
    }

    // MARK: VM configuration

    func makeConfiguration() throws -> VZVirtualMachineConfiguration {
        let vz = VZVirtualMachineConfiguration()
        vz.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                          min(config.cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        vz.memorySize = min(UInt64(config.memoryGiB) << 30, VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        let platform = VZGenericPlatformConfiguration()
        if let data = try? Data(contentsOf: Paths.machineID),
           let id = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = id
        } else {
            try platform.machineIdentifier.dataRepresentation.write(to: Paths.machineID)
        }
        vz.platform = platform

        let loader = VZLinuxBootLoader(kernelURL: Paths.kernel)
        // A kernel that mounts the root disk itself skips the initramfs (~0.2 s of every boot).
        loader.initialRamdiskURL = FileManager.default.fileExists(atPath: Paths.kernelMountsRoot.path) ? nil : Paths.initrd
        // init_on_alloc=0: Alpine's kernel zeroes every page it allocates, including the ones it hands
        // to the memory balloon, which would touch gigabytes the guest is giving away (and
        // Virtualization.framework keeps charging the VM for every page the guest has ever touched).
        // (init_on_free=1 is no better: it zeroes all of memory at boot.)
        // rcu_expedited and quick force-quiescent-state scans: shorter RCU grace periods, which network
        // namespace setup and teardown wait on at every container start and stop.
        loader.commandLine = "root=/dev/vda2 ro rootwait rootfstype=ext4 modules=ext4 console=hvc0 quiet init_on_alloc=0 " +
            "rcupdate.rcu_expedited=1 rcutree.jiffies_till_first_fqs=0 rcutree.jiffies_till_next_fqs=1"
        vz.bootLoader = loader

        let sync: VZDiskImageSynchronizationMode = switch config.diskSync {
        case "full": .full
        case "none": .none
        default: .fsync
        }
        // .cached + .fsync is what Docker Desktop uses (add_disk passes cachingMode 2, sync 2);
        // .automatic has a history of ext4 journal corruption under Virtualization.framework.
        func disk(_ url: URL, readOnly: Bool = false) throws -> VZVirtioBlockDeviceConfiguration {
            VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(
                url: url, readOnly: readOnly, cachingMode: .cached, synchronizationMode: sync))
        }
        // Order matters: the guest expects boot=vda, data=vdb.
        vz.storageDevices = [try disk(Paths.bootDisk), try disk(Paths.dataDisk), try disk(Paths.seed, readOnly: true)]

        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        if let mac = VZMACAddress(string: config.mac) { net.macAddress = mac }
        vz.networkDevices = [net]

        var shares: [VZDirectorySharingDeviceConfiguration] = []
        for share in config.shares where FileManager.default.fileExists(atPath: share.host) {
            let device = VZVirtioFileSystemDeviceConfiguration(tag: share.tag)
            device.share = VZSingleDirectoryShare(directory: VZSharedDirectory(
                url: URL(fileURLWithPath: share.host), readOnly: false))
            shares.append(device)
        }
        if config.rosetta {
            switch VZLinuxRosettaDirectoryShare.availability {
            case .installed:
                let device = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
                let rosetta = try VZLinuxRosettaDirectoryShare()
                // Ahead-of-time cache (mdock set aot=on): rosettad in the guest keeps translated code,
                // so amd64 programs aren't translated again on every run (Guest.agentScript starts it).
                if #available(macOS 14, *), config.aot {
                    do { try rosetta.setCachingOptions(.defaultUnixSocket) } catch { log("rosetta cache unavailable: \(error)") }
                }
                device.share = rosetta
                shares.append(device)
            case .notInstalled:
                log("Rosetta is not installed; run: softwareupdate --install-rosetta")
            default:
                log("Rosetta is not supported on this host")
            }
        }
        vz.directorySharingDevices = shares

        vz.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        vz.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = try VZFileSerialPortAttachment(url: Paths.console, append: false)
        vz.serialPorts = [console]

        try vz.validate()
        return vz
    }

    // MARK: Lifecycle

    func run() throws {
        signal(SIGPIPE, SIG_IGN)
        raiseDescriptorLimit()
        // One daemon at a time: a second one (say launchd's RunAtLoad while a `mdock start` daemon
        // runs) would steal the sockets. The lock goes away with the process.
        let lockFD = open(Paths.daemonLock.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            log("another mdock daemon is already running")
            refuseQueuedClients("another mdock daemon is running")
            exit(0)
        }
        reopenLogIfRotated()
        if LaunchAgent.supervising, LaunchAgent.crashLooping() {
            log("mdock keeps failing to start; not retrying until `mdock start` (see the log above)")
            refuseQueuedClients("mdock keeps failing to start: see ~/.mdock/daemon.log, then run mdock start")
            exit(0)
        }
        try? FileManager.default.removeItem(at: Paths.idleMarker)
        // launchd starts the daemon directly at login, without `mdock start`: pick up a guest kernel
        // upgrade here as well. Safe now that no other daemon (and so no VM) can be using the disk.
        do { try extractKernel() } catch { log("kernel refresh skipped: \(error)") }
        do { try Workspace.mount(quiet: true) } catch { log("workspace not mounted: \(error)") }
        // Accelerator services a previous daemon left behind when it died abruptly (reparented to
        // launchd, still holding memory and sockets).
        for name in Accel.services.compactMap(\.binary) {
            _ = try? mdock.run("/usr/bin/pkill", ["-P", "1", "-f", "/\(name) serve "], quiet: true)
        }
        Sync.resume()
        try "\(getpid())\n".write(to: Paths.pid, atomically: true, encoding: .utf8)
        if config.gpu {
            try runKrun()
            return
        }
        let configuration = try makeConfiguration()

        queue.sync {
            vm = VZVirtualMachine(configuration: configuration, queue: queue)
            vm.delegate = self
        }
        try serveDockerSocket()
        try serveInternalSocket()
        try serveControlSocket()
        claimDefaultSocket()
        installSignalHandlers()

        queue.async { [self] in
            notifyListener.delegate = self
            let device = vm.socketDevices.first as? VZVirtioSocketDevice
            for port in [Guest.notifyPort, Guest.hostForwardPort] + Accel.services.map(\.port) {
                device?.setSocketListener(notifyListener, forPort: port)
            }
            startedAt = Date()
            vm.start { result in
                if case .failure(let error) = result {
                    log("VM failed to start: \(error)")
                    self.cleanupAndExit(1)
                }
                log("VM started: \(self.config.cpus) vCPUs, \(self.config.memoryGiB) GiB")
            }
        }
        startContainerWatcher()
        startWatchdog()
        dispatchMain()
    }

    /// launchd starts jobs with a soft limit of 256 descriptors. Every docker client, published-port
    /// connection and accelerator call takes two here, and on the GPU engine libkrun (a child, which
    /// inherits the limit) keeps each finished vsock connection's socket for 5 s: a burst of API
    /// calls ran out, refused connections, and once aborted the VM.
    private func raiseDescriptorLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        for want in [rlim_t(65536), rlim_t(OPEN_MAX)] where limit.rlim_cur < want {
            var raised = limit
            raised.rlim_cur = min(want, limit.rlim_max)
            if setrlimit(RLIMIT_NOFILE, &raised) == 0 { return }
        }
    }

    // MARK: GPU engine (libkrun)

    private var children: [pid_t] = []
    private var vmmPID: pid_t = 0

    private func runKrun() throws {
        guard let gvproxy = Krun.gvproxy else { throw CommandError(description: "GPU stack not built; run gpu/build.sh") }
        for port in [Guest.dockerPort, Guest.relayPort, Guest.poweroffPort, Guest.notifyPort] { unlink(Krun.socketPath(port)) }
        unlink(Krun.networkSocket.path)

        let gv = try spawn(gvproxy, ["-listen-vfkit", "unixgram://\(Krun.networkSocket.path)", "-ssh-port", "-1", "-mtu", "1500"],
                           log: Krun.gvproxyLog)
        children.append(gv)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: Krun.networkSocket.path) { usleep(20_000) }

        // Guest -> host notifications arrive on a unix socket libkrun connects to.
        let notify = try Sockets.unixListen(Krun.socketPath(Guest.notifyPort))
        Sockets.acceptLoop(notify) { [self] fd in
            Thread.detachNewThread { [self] in
                defer { close(fd) }
                if let line = Sockets.readLine(fd) { handleNotification(line.split(separator: " ").map(String.init)) }
            }
        }

        for service in Accel.services {
            let listener = try Sockets.unixListen(Accel.krunSocket(service.port))
            Sockets.acceptLoop(listener) { [self] fd in accel.handle(fd, port: service.port) }
        }

        startedAt = Date()
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        vmmPID = try spawn(exe, ["krun-vmm"], log: Paths.daemonLog)
        children.append(vmmPID)
        try serveDockerSocket()
        try serveInternalSocket()
        try serveControlSocket()
        claimDefaultSocket()
        installSignalHandlers()

        // The VM is a child process: when it exits, so do we (and gvproxy).
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            waitpid(vmmPID, &status, 0)
            log("GPU VM exited (status \(status))")
            cleanupAndExit(exitStatus)
        }
        startContainerWatcher()
        startWatchdog()
        dispatchMain()
    }

    private func spawn(_ tool: String, _ args: [String], log logURL: URL) throws -> pid_t {
        if logURL != Paths.daemonLog { rotateLog(logURL) }
        let logFD = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        defer { close(logFD) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, logFD, 1)
        posix_spawn_file_actions_adddup2(&actions, logFD, 2)
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = ([tool] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let rc = withChildSpawnAttributes { posix_spawn(&pid, tool, &actions, $0, argv, environ) }
        guard rc == 0 else { throw CommandError(description: "spawn \(tool): \(String(cString: strerror(rc)))") }
        return pid
    }

    /// The guest agent reports every 5 s over vsock. Silence means the vsock link (and with it
    /// docker.sock and every accel relay) is stuck; surface that instead of hanging quietly. Under
    /// launchd, a link that stays dead (and docker unreachable) gets the VM restarted.
    private func startWatchdog() {
        Thread.detachNewThread { [self] in
            while true {
                sleep(10)
                reopenLogIfRotated()
                let silent = stateLock.withLock { ready ? Double(DispatchTime.now().uptimeNanoseconds - lastGuestReport) / 1e9 : 0 }
                if silent > 30 {
                    stateLock.withLock {
                        if !bridgeStalled {
                            bridgeStalled = true
                            log("guest bridge unresponsive for 30s: vsock stalled? docker and accel calls will hang")
                        }
                    }
                }
                if silent > 120, LaunchAgent.supervising, !dockerPing() {
                    log("guest bridge dead for \(Int(silent))s and docker unreachable; restarting the VM")
                    stop(status: 75)
                    return
                }
            }
        }
    }

    /// GET /_ping through the vsock bridge, with deadlines on both connect and reply.
    private func dockerPing() -> Bool {
        guard let fd = vsockConnect(Guest.dockerPort) else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        Sockets.writeAll(fd, "GET /_ping HTTP/1.0\r\nHost: docker\r\n\r\n")
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buffer, buffer.count)
        return n > 0 && String(decoding: buffer[..<n], as: UTF8.self).hasPrefix("HTTP/1.0 200")
    }

    /// Rotates daemon.log when it grows too big and points stdout/stderr at the fresh file (only when
    /// they aren't a terminal, i.e. when they are that log).
    private func reopenLogIfRotated() {
        guard isatty(STDERR_FILENO) == 0, rotateLog(Paths.daemonLog) else { return }
        let fd = open(Paths.daemonLog.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)
        close(fd)
    }

    /// Docker Desktop's privileged helper keeps /var/run/docker.sock pointing at
    /// ~/.docker/run/docker.sock. While Desktop isn't serving that path, point it at mdock so tools
    /// hard-wired to the default socket work too. A live Docker Desktop socket is left alone.
    private func claimDefaultSocket() {
        let path = Paths.desktopSocket.path, ours = Paths.dockerSocket.path
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == ours { return }
        if let fd = Sockets.unixConnect(path) {
            close(fd)
            log("~/.docker/run/docker.sock is served by Docker Desktop; leaving it alone")
            return
        }
        try? FileManager.default.createDirectory(at: Paths.desktopSocket.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        unlink(path)
        if symlink(ours, path) == 0 { log("~/.docker/run/docker.sock -> \(ours)") }
    }

    private func releaseDefaultSocket() {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: Paths.desktopSocket.path)) == Paths.dockerSocket.path {
            unlink(Paths.desktopSocket.path)
        }
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [self] in stop() }
            source.resume()
            signalSources.append(source)
        }
    }
    private var signalSources: [DispatchSourceSignal] = []

    /// Clean shutdown: ask the guest agent to power off, fall back to the virtual
    /// power button, and only pull the plug if the guest ignores both. The daemon then exits with
    /// `status` (75 makes launchd start it again).
    func stop(status: Int32 = 0) {
        // The first call runs the shutdown; a requested stop (0) always wins over a restart (75).
        let first = stateLock.withLock { () -> Bool in
            let first = stopStatus == nil
            if first || status == 0 { stopStatus = status }
            return first
        }
        guard first else { return }
        log("stopping VM")
        Thread.detachNewThread { [self] in
            if let fd = vsockConnect(Guest.poweroffPort) {
                Sockets.writeAll(fd, "poweroff\n")
                close(fd)
            }
        }
        if config.gpu {
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [self] in
                log("guest did not shut down; killing the VM")
                kill(vmmPID, SIGKILL)
            }
            return
        }
        queue.asyncAfter(deadline: .now() + 15) { [self] in
            log("guest still running; pressing the power button")
            if vm.canRequestStop { try? vm.requestStop() }
        }
        queue.asyncAfter(deadline: .now() + 60) { [self] in
            log("guest did not shut down; forcing stop")
            vm.stop { _ in self.cleanupAndExit(self.exitStatus) }
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        log(stateLock.withLock { stopStatus } == nil ? "guest stopped by itself" : "guest stopped")
        cleanupAndExit(exitStatus)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        log("VM stopped with error: \(error)")
        cleanupAndExit(1)
    }

    private func cleanupAndExit(_ code: Int32) {
        for child in children { kill(child, SIGTERM) }
        accel.stopAll()
        let (activated, idle) = stateLock.withLock { (socketActivated, idleStopped) }
        if idle {
            // launchd keeps listening on docker.sock (and the default socket keeps pointing at it):
            // the next docker command starts mdock again. A clean idle stop isn't a crash.
            FileManager.default.createFile(atPath: Paths.idleMarker.path, contents: Data("\(Int(Date().timeIntervalSince1970))\n".utf8))
            try? FileManager.default.removeItem(at: Paths.starts)
        } else if !activated || code == 0 {
            // A requested stop. (A restart keeps launchd's socket where clients find it.)
            releaseDefaultSocket()
            unlink(Paths.dockerSocket.path)
        }
        for path in [Paths.controlSocket, Paths.internalSocket, Paths.pid] { unlink(path.path) }
        exit(code)
    }

    // MARK: Guest notifications

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        let fd = dup(connection.fileDescriptor)
        connection.close()
        if connection.destinationPort == Guest.hostForwardPort {
            handleHostForward(fd)
            return true
        }
        if connection.destinationPort != Guest.notifyPort {
            accel.handle(fd, port: connection.destinationPort)
            return true
        }
        Thread.detachNewThread { [self] in
            defer { close(fd) }
            guard let line = Sockets.readLine(fd) else { return }
            handleNotification(line.split(separator: " ").map(String.init))
        }
        return true
    }

    private func handleNotification(_ words: [String]) {
        guard let kind = words.first else { return }
        switch kind {
        case "ready" where words.count >= 2:
            if !config.gpu { Thread.detachNewThread { [self] in startDialBack(words[1]) } }
            stateLock.withLock {
                guestIP = words[1]
                if !ready {
                    ready = true
                    readyAt = Date()
                    log(String(format: "guest ready at %@ after %.1fs", words[1], readyAt!.timeIntervalSince(startedAt)))
                    Thread.detachNewThread { [self] in
                        Sync.reconnect {
                            ((dockerGET("/containers/\(Sync.container)/json") as? [String: Any])?["State"] as? [String: Any])?["Running"] as? Bool == true
                        }
                    }
                }
            }
            requestSync()
        case "k8s" where words.count >= 2:
            let state = words[1]
            let version = ["up", "starting"].contains(state) && words.count > 2 && words[2] != "-" ? words[2] : ""
            let ports = state == "up" ? Array(words.dropFirst(3)).sorted() : []
            let changed = stateLock.withLock { () -> Bool in
                defer { (k8sState, k8sVersion, k8sPorts) = (state, version, ports) }
                return (k8sState, k8sPorts) != (state, ports)
            }
            if changed {
                log("kubernetes \(state)\(ports.isEmpty ? "" : ", LoadBalancer ports \(ports.joined(separator: " "))")")
                requestSync()
            }
        case "hostnet":
            let ports = Array(words.dropFirst()).sorted()
            let changed = stateLock.withLock { () -> Bool in
                defer { hostNetPorts = ports }
                return hostNetPorts != ports
            }
            if changed {
                log("host-network listeners: \(ports.isEmpty ? "none" : ports.joined(separator: " "))")
                requestSync()
            }
        case "tso" where words.count >= 2:
            stateLock.withLock { tso = words[1] == "1" }
        case "binfmt":
            stateLock.withLock { binfmt = Array(words.dropFirst()) }
        case "kernel" where words.count >= 2:
            try? words[1].write(to: Paths.guestKernelStamp, atomically: true, encoding: .utf8)
            if words.count >= 3 { stateLock.withLock { kernelRelease = words[2] } }
        case "mem" where words.count >= 3:
            guard let total = Int(words[1]), let avail = Int(words[2]) else { return }
            stateLock.withLock {
                lastGuestReport = DispatchTime.now().uptimeNanoseconds
                if bridgeStalled { bridgeStalled = false; log("guest bridge recovered") }
            }
            let ballooned = words.count > 3 ? Int(words[3]) ?? 0 : 0
            stateLock.withLock { memTotalKiB = total - ballooned; memAvailKiB = avail }
            if config.autoBalloon && !config.gpu { adjustBalloon(usedKiB: total - avail - ballooned, availKiB: avail) }
        default:
            log("unknown guest notification: \(words.joined(separator: " "))")
        }
    }

    /// Keeps guest RAM near what it actually uses so idle memory goes back to macOS.
    /// Grows immediately under pressure; shrinks only after 3 consecutive low reports (~15s).
    private func adjustBalloon(usedKiB: Int, availKiB: Int) {
        let maxMiB = config.memoryGiB * 1024
        let usedMiB = max(0, usedKiB / 1024)
        // Headroom past what the guest uses: enough for a burst between reports (and the guest's
        // deflate-on-OOM covers the rest), small enough that its page cache can't grow without bound.
        // It must stay above the 1 GiB that counts as pressure below, or the balloon would see-saw.
        let headroom = max(1536, usedMiB / 3)
        var target = min(maxMiB, max(2048, usedMiB + headroom))
        target = (target + 255) / 256 * 256

        stateLock.lock()
        let current = balloonMiB == 0 ? maxMiB : balloonMiB
        var apply = false
        if availKiB < 1024 * 1024 || target > current {
            target = availKiB < 1024 * 1024 ? maxMiB : target
            apply = target != current
            shrinkVotes = 0
        } else if current - target >= 512 {
            shrinkVotes += 1
            apply = shrinkVotes >= 3
        } else {
            shrinkVotes = 0
        }
        if apply { balloonMiB = target; shrinkVotes = 0 }
        stateLock.unlock()

        guard apply else { return }
        queue.async { [self] in
            guard let balloon = vm.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice else { return }
            balloon.targetVirtualMachineMemorySize = UInt64(target) << 20
            log("balloon target \(target) MiB (guest using \(usedMiB) MiB)")
        }
    }

    // MARK: Vsock

    /// Opens a vsock stream to the guest. Blocks the calling thread (never call on `queue`).
    func vsockConnect(_ port: UInt32) -> Int32? {
        if config.gpu { return Sockets.unixConnect(Krun.socketPath(port)) }
        let done = DispatchSemaphore(value: 0)
        var fd: Int32?
        queue.async { [self] in
            guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else { done.signal(); return }
            device.connect(toPort: port) { result in
                if case .success(let connection) = result {
                    let copy = dup(connection.fileDescriptor)
                    connection.close()
                    if copy >= 0 {
                        // The host end is a unix socket: macOS defaults to 8 KiB buffers, which caps
                        // how much Virtualization.framework moves per wakeup.
                        var size: Int32 = 4 << 20
                        for option in [SO_RCVBUF, SO_SNDBUF] {
                            setsockopt(copy, SOL_SOCKET, option, &size, socklen_t(MemoryLayout<Int32>.size))
                        }
                        fd = copy
                    }
                }
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + 5)
        return fd
    }

    private func serveDockerSocket() throws {
        if let listener = LaunchAgent.activatedSocket("docker") {
            stateLock.withLock { socketActivated = true }
            Thread.detachNewThread { [self] in serveActivated(listener) }
            return
        }
        let listener = try Sockets.unixListen(Paths.dockerSocket.path)
        Sockets.acceptLoop(listener) { [self] client in serveDockerClient(client) }
    }

    /// Paths.internalSocket: the same Docker API, not counted as a client.
    private func serveInternalSocket() throws {
        let listener = try Sockets.unixListen(Paths.internalSocket.path)
        Sockets.acceptLoop(listener) { [self] client in
            Thread.detachNewThread { [self] in
                guard waitUntilReady(), let guest = dockerConnect() else { close(client); return }
                Sockets.splice(client, guest.fd, vsock: guest.vsock ? guest.fd : nil)
            }
        }
    }

    /// Accepts on launchd's docker.sock and, between accepts, decides whether to stop for being idle.
    /// Deciding on this thread means a client is either served or left queued in launchd's socket,
    /// where it starts the next run: none is ever dropped.
    private func serveActivated(_ listener: Int32) {
        var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        while true {
            if poll(&pfd, 1, 10_000) > 0 {
                let client = accept(listener, nil, nil)
                if client >= 0 {
                    var one: Int32 = 1
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    serveDockerClient(client)
                }
                continue
            }
            guard idleExpired() else { continue }
            close(listener)
            stateLock.withLock { idleStopped = true }
            log("no containers running and no docker clients for \(idleMinutes()) min: stopping the VM; the next docker command starts it again")
            Sync.pause()
            stop(status: 0)
            return
        }
    }

    private func serveDockerClient(_ client: Int32) {
        stateLock.withLock { dockerClients += 1 }
        Thread.detachNewThread { [self] in
            let finished = { [self] in
                stateLock.withLock {
                    dockerClients -= 1
                    lastDockerUse = DispatchTime.now().uptimeNanoseconds
                }
            }
            // A command that started mdock (or arrived while it boots) waits for Docker, not an error.
            guard waitUntilReady(), let guest = dockerConnect() else {
                close(client)
                finished()
                return
            }
            Sockets.splice(client, guest.fd, vsock: guest.vsock ? guest.fd : nil, onClose: finished)
        }
    }

    /// Up to 3 minutes for the guest to report ready; false if the VM is stopping instead.
    private func waitUntilReady() -> Bool {
        for _ in 0..<3600 {
            let (isReady, stopping) = stateLock.withLock { (ready, stopStatus != nil) }
            if isReady { return true }
            if stopping { return false }
            usleep(50_000)
        }
        return false
    }

    /// Idle: booted, no docker.sock clients for `config.idle` minutes, no containers running except
    /// mdock's own, Kubernetes off. The container count comes from container events; Docker
    /// confirms it before anything stops.
    private func idleExpired() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let (candidate, quietFor) = stateLock.withLock {
            (ready && stopStatus == nil && dockerClients == 0 && busyContainers == 0 && k8sState == "off", now - lastDockerUse)
        }
        // Read the setting each time, so `mdock set idle=N` applies without a restart.
        let minutes = idleMinutes()
        guard candidate, minutes > 0, quietFor >= UInt64(minutes) * 60_000_000_000, let running = dockerGET("/containers/json") as? [[String: Any]] else { return false }
        let busy = userContainers(running)
        stateLock.withLock { busyContainers = busy }
        guard busy == 0 else { return false }
        if let name = restartedOnBoot() {
            if stateLock.withLock({ () -> Bool in defer { idleVeto = name }; return idleVeto != name }) {
                log("not stopping while idle: Docker would start \(name) again when the VM boots (its restart policy)")
            }
            return false
        }
        return true
    }

    /// A stopped container Docker would start again when the VM boots: restart policy `always`, or
    /// `on-failure` after an error exit. Stopping the VM while idle would bring back a container
    /// someone stopped, so idle stop waits.
    private func restartedOnBoot() -> String? {
        // filters={"status":["exited"]}
        guard let stopped = dockerGET("/containers/json?all=1&filters=%7B%22status%22%3A%5B%22exited%22%5D%7D") as? [[String: Any]] else { return nil }
        for container in stopped where (container["Labels"] as? [String: Any])?["com.mdock.internal"] == nil {
            guard let id = container["Id"] as? String, let detail = dockerGET("/containers/\(id)/json") as? [String: Any],
                  let policy = ((detail["HostConfig"] as? [String: Any])?["RestartPolicy"] as? [String: Any])?["Name"] as? String else { continue }
            let exitCode = (detail["State"] as? [String: Any])?["ExitCode"] as? Int ?? 0
            if policy == "always" || (policy == "on-failure" && exitCode != 0) {
                return (container["Names"] as? [String])?.first.map { String($0.dropFirst()) } ?? String(id.prefix(12))
            }
        }
        return nil
    }

    private func idleMinutes() -> Int { (try? loadConfig())?.idle ?? config.idle }

    private func userContainers(_ containers: [[String: Any]]) -> Int {
        containers.filter { ($0["Labels"] as? [String: Any])?["com.mdock.internal"] == nil }.count
    }

    /// When launchd started us for clients but the daemon won't run, answer them with an error rather
    /// than leave them hanging (launchd would also keep starting mdock for them).
    private func refuseQueuedClients(_ message: String) {
        guard let listener = LaunchAgent.activatedSocket("docker") else { return }
        let body = #"{"message":"\#(message)"}"#
        var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        while poll(&pfd, 1, 0) > 0 {
            let client = accept(listener, nil, nil)
            if client < 0 { break }
            Sockets.writeAll(client, "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\n"
                             + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
            close(client)
        }
        close(listener)
    }

    // MARK: Control socket

    private func serveControlSocket() throws {
        let listener = try Sockets.unixListen(Paths.controlSocket.path)
        Sockets.acceptLoop(listener) { [self] client in
            Thread.detachNewThread { [self] in
                defer { close(client) }
                let command = Sockets.readLine(client) ?? ""
                switch command {
                case "stop":
                    Sockets.writeAll(client, "ok\n")
                    stop()
                default:
                    Sockets.writeAll(client, statusJSON() + "\n")
                }
            }
        }
    }

    private func statusJSON() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }
        let status: [String: Any] = [
            "pid": Int(getpid()),
            "engine": config.gpu ? "krun (GPU)" : "vz",
            "ready": ready,
            "ip": guestIP ?? "",
            "cpus": config.cpus,
            "memoryGiB": config.memoryGiB,
            "balloonMiB": balloonMiB == 0 ? config.memoryGiB * 1024 : balloonMiB,
            "guestMemTotalMiB": memTotalKiB / 1024,
            "guestMemAvailableMiB": memAvailKiB / 1024,
            "bootSeconds": readyAt.map { $0.timeIntervalSince(startedAt) } ?? -1,
            "forwards": forwards.keys.sorted(),
            // How published ports reach the guest right now (already under stateLock).
            "portPath": config.gpu ? "relay" : dialBackFailed ? "relay (fallback)" : "direct",
            "bridgeStalled": bridgeStalled,
            "supervised": LaunchAgent.supervising,
            "kubernetes": ["state": k8sState, "version": k8sVersion, "ports": k8sPorts],
            "tso": tso.map { $0 as Any } ?? NSNull(),
            "x86": Daemon.translators(binfmt),
            "rosettaAOT": config.aot,
            "kernel": kernelRelease,
            "accel": accel.status(),
            "idleStop": [
                "enabled": socketActivated && idleMinutes() > 0,
                "minutes": idleMinutes(),
                "containers": busyContainers,
                "dockerClients": dockerClients,
                "quietSeconds": Int((DispatchTime.now().uptimeNanoseconds - lastDockerUse) / 1_000_000_000),
            ] as [String: Any],
        ]
        let data = try! JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: host.docker.internal

    /// host.docker.internal over vsock (until dial-back is up, and on an older guest): mdock-guestd sends
    /// "<port>\n"; once connected to the Mac's own loopback (IPv4, then IPv6, where `localhost` servers
    /// often bind) this side answers one byte (1) and the connection's bytes follow. Loopback isn't
    /// subject to Local Network privacy, so this works under launchd too.
    private func handleHostForward(_ fd: Int32) {
        Thread.detachNewThread { [self] in
            guard let line = Sockets.readLine(fd, limit: 16), let port = UInt16(line), port > 0 else {
                close(fd)
                return
            }
            forwardToMac(fd, port: port, vsock: true)
        }
    }

    /// Connects a host.docker.internal connection mdock-guestd made (over vsock, or over the VM's
    /// network through DialBack) to `port` on the Mac's own loopback.
    private func forwardToMac(_ fd: Int32, port: UInt16, vsock: Bool) {
        guard let upstream = Sockets.tcpConnect(host: "127.0.0.1", port: port) ?? Sockets.tcp6Connect(host: "::1", port: port) else {
            close(fd)  // mdock-guestd resets the client: the port is closed on the Mac
            return
        }
        Sockets.writeAll(fd, "\u{1}")  // connected
        Sockets.splice(fd, upstream, vsock: vsock ? fd : nil)
    }

    // MARK: File events

    /// Bind mounts see edits made on the Mac but get no inotify events, which file watchers (vite,
    /// webpack, nodemon, Django, ...) rely on. FSEvents watches the bind-mount sources of running
    /// containers; changed paths go to mdock-guestd, which raises IN_ATTRIB on them in the VM.
    private var eventStream: FSEventStreamRef?
    private var watchedRoots: [String] = []
    private let fileEventQueue = DispatchQueue(label: "mdock.fsevents")
    private var pendingPaths = Set<String>()
    /// mtime last forwarded per path: an event with the same mtime is our own chmod echoing back.
    private var forwardedMtime: [String: Int] = [:]

    /// Longest-prefix mapping between Mac paths and guest paths through the virtiofs shares.
    private func translate(_ path: String, toGuest: Bool) -> String? {
        let pairs = config.shares.map { toGuest ? ($0.host, $0.guest) : ($0.guest, $0.host) }
        guard let (from, to) = pairs.filter({ path == $0.0 || path.hasPrefix($0.0 + "/") })
            .max(by: { $0.0.count < $1.0.count }) else { return nil }
        return to + path.dropFirst(from.count)
    }

    private func syncFileWatches(_ containers: [[String: Any]]) {
        var roots = Set<String>()
        for container in containers {
            for mount in container["Mounts"] as? [[String: Any]] ?? [] where mount["Type"] as? String == "bind" {
                if let source = mount["Source"] as? String, let host = translate(source, toGuest: false) { roots.insert(host) }
            }
        }
        // A parent already covers its subdirectories.
        let sorted = roots.sorted()
        let minimal = sorted.filter { root in !sorted.contains { $0 != root && root.hasPrefix($0 + "/") } }
        fileEventQueue.sync {
            guard minimal != watchedRoots else { return }
            watchedRoots = minimal
            if let stream = eventStream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                eventStream = nil
            }
            guard !minimal.isEmpty else { return }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents |
                                                 kFSEventStreamCreateFlagNoDefer)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                let daemon = Unmanaged<Daemon>.fromOpaque(info).takeUnretainedValue()
                let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                daemon.fileEvents(list, Array(UnsafeBufferPointer(start: flags, count: count)))
            }
            guard let stream = FSEventStreamCreate(nil, callback, &context, minimal as CFArray,
                                                   FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.03, flags) else { return }
            FSEventStreamSetDispatchQueue(stream, fileEventQueue)
            FSEventStreamStart(stream)
            eventStream = stream
            log("watching \(minimal.count) bind mount\(minimal.count == 1 ? "" : "s") for file changes")
        }
    }

    /// Runs on fileEventQueue. FSEvents flags accumulate per path, so they can't tell our own chmod
    /// echoing back (which only moves the ctime) from a real change; the mtime can. A path goes to the
    /// guest only when its mtime differs from the one last sent (-1 = gone).
    private func fileEvents(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        let relevant = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved |
                                               kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified)
        func mtime(_ path: String) -> Int {
            var st = stat()
            return lstat(path, &st) == 0 ? Int(st.st_mtimespec.tv_sec) * 1_000_000_000 + st.st_mtimespec.tv_nsec : -1
        }
        for (path, flag) in zip(paths, flags) where flag & relevant != 0 {
            let now = mtime(path)
            guard forwardedMtime[path] != now else { continue }
            if forwardedMtime.count > 50_000 { forwardedMtime.removeAll() }
            forwardedMtime[path] = now
            // A vanished path makes the guest poke its directory; that echo must not bounce back either.
            if now == -1 {
                let parent = (path as NSString).deletingLastPathComponent
                forwardedMtime[parent] = mtime(parent)
            }
            if let guest = translate(path, toGuest: true) { pendingPaths.insert(guest) }
        }
        guard !pendingPaths.isEmpty else { return }
        fileEventQueue.asyncAfter(deadline: .now() + 0.02) { [self] in flushFileEvents() }
    }

    private func flushFileEvents() {
        guard !pendingPaths.isEmpty else { return }
        var paths = Array(pendingPaths)
        pendingPaths.removeAll()
        // Mass changes (checkouts, installs): poke the directories rather than every file.
        if paths.count > 256 { paths = Array(Set(paths.map { ($0 as NSString).deletingLastPathComponent })) }
        Thread.detachNewThread { [self] in
            guard let fd = vsockConnect(Guest.fileEventsPort) else { return }
            Sockets.writeAll(fd, paths.joined(separator: "\n") + "\n")
            close(fd)
        }
    }

    // MARK: Port forwarding

    /// Follows container start/stop: mirrors published ports onto macOS (like Docker Desktop) and
    /// keeps the file-event watches on bind mounts current. The event stream is only ever read here;
    /// the work happens on the sync worker, so a burst of events (many containers removed at once)
    /// never leaves the stream unread, which would stall the VM's vsock device and with it the
    /// very API call the sync is waiting on.
    private func startContainerWatcher() {
        Thread.detachNewThread { [self] in
            while true {
                // Straight to the VM, not through docker.sock: mdock's own calls aren't clients.
                if stateLock.withLock({ ready }), let fd = vsockConnect(Guest.dockerPort) {
                    let filter = #"{"type":["container"],"event":["start","die","stop","kill","destroy"]}"#
                        .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                    Sockets.writeAll(fd, "GET /events?filters=\(filter) HTTP/1.0\r\nHost: docker\r\n\r\n")
                    requestSync()
                    var buffer = [UInt8](repeating: 0, count: 65536)
                    while read(fd, &buffer, buffer.count) > 0 {
                        requestSync()
                    }
                    close(fd)
                }
                sleep(1)
            }
        }
        Thread.detachNewThread { [self] in
            while true {
                syncRequested.wait()
                usleep(100_000)  // let a burst of events settle into one pass
                stateLock.withLock { syncPending = false }
                syncForwards()
            }
        }
    }

    private let syncRequested = DispatchSemaphore(value: 0)
    private var syncPending = false

    /// Schedules syncForwards() on the sync worker; requests while one is pending coalesce.
    func requestSync() {
        let first = stateLock.withLock { () -> Bool in
            defer { syncPending = true }
            return !syncPending
        }
        if first { syncRequested.signal() }
    }

    private let syncLock = NSLock()

    func syncForwards() {
        syncLock.lock()
        defer { syncLock.unlock() }
        guard let ip = stateLock.withLock({ guestIP }), let containers = dockerGET("/containers/json") as? [[String: Any]] else {
            return
        }
        syncFileWatches(containers)
        let busy = userContainers(containers)
        stateLock.withLock {
            // The idle clock starts when the last container stops (a job that ends on its own, say).
            if busy > 0 || busyContainers > 0 { lastDockerUse = DispatchTime.now().uptimeNanoseconds }
            busyContainers = busy
        }
        var wanted: [String: (host: String?, port: UInt16, udp: Bool)] = [:]
        // Kubernetes: the API on the Mac's loopback (as https://127.0.0.1:6443) and LoadBalancer
        // services on localhost, like Docker Desktop. k3s's ServiceLB answers on the guest's loopback.
        let (k8s, lbPorts, hostNet) = stateLock.withLock { (k8sState, k8sPorts, hostNetPorts) }
        // --network host: what a container listens on in the VM appears on the Mac, as on Linux.
        // Loopback-only listeners stay loopback-only.
        for spec in hostNet where config.forwardPorts {
            let parts = spec.split(separator: ":")
            guard parts.count == 3, let port = UInt16(parts[1]) else { continue }
            let host: String? = parts[2] == "lo" ? "127.0.0.1" : nil
            let udp = parts[0] == "udp"
            wanted["\(host ?? "*"):\(port)\(udp ? "/udp" : "")"] = (host, port, udp)
        }
        if k8s == "up" || k8s == "starting" { wanted["127.0.0.1:6443"] = ("127.0.0.1", 6443, false) }
        for spec in lbPorts where config.forwardPorts {
            let parts = spec.split(separator: "/")
            guard let port = UInt16(parts[0]) else { continue }
            let udp = parts.count > 1 && parts[1].uppercased() == "UDP"
            wanted["*:\(port)\(udp ? "/udp" : "")"] = (nil, port, udp)
        }
        for container in containers where config.forwardPorts {
            for port in container["Ports"] as? [[String: Any]] ?? [] {
                let type = port["Type"] as? String
                guard type == "tcp" || type == "udp", let pub = port["PublicPort"] as? Int,
                      let p = UInt16(exactly: pub) else { continue }
                let bindIP = port["IP"] as? String ?? ""
                if bindIP == "::1" { continue }
                let host: String? = bindIP == "127.0.0.1" ? "127.0.0.1" : nil
                wanted["\(host ?? "*"):\(p)\(type == "udp" ? "/udp" : "")"] = (host, p, type == "udp")
            }
        }

        let existing = stateLock.withLock { forwards }
        for (key, cancel) in existing where wanted[key] == nil {
            cancel.set()
            stateLock.withLock { _ = forwards.removeValue(forKey: key) }
            log("forward \(key) removed")
        }
        for (key, spec) in wanted where existing[key] == nil {
            do {
                // macOS lets only root bind low ports on loopback; take every interface instead and
                // turn away peers that aren't on this Mac.
                let lowLoopback = spec.host == "127.0.0.1" && spec.port < 1024
                let bindHost = lowLoopback ? nil : spec.host
                if spec.udp {
                    // Over the vsock relay: datagrams have no connection for the guest to dial back.
                    let forward = try UDPForward(host: bindHost, port: spec.port, connect: { [self] port in udpRelayConnect(port) },
                                                 loopbackOnly: lowLoopback)
                    stateLock.withLock { forwards[key] = forward.cancel }
                    log("forward \(key) -> \(ip):\(spec.port)")
                    continue
                }
                let listener = try Sockets.tcpListen(host: bindHost, port: spec.port)
                let cancel = Cancel()
                Sockets.acceptLoop(listener, cancel: cancel) { [self] client in
                    if lowLoopback && !Sockets.peerIsLoopback(client) {
                        close(client)
                        return
                    }
                    Thread.detachNewThread { [self] in
                        guard let upstream = forwardConnect(spec.port) else {
                            close(client)
                            return
                        }
                        Sockets.splice(client, upstream.fd, vsock: upstream.vsock ? upstream.fd : nil)
                    }
                }
                stateLock.withLock { forwards[key] = cancel }
                log("forward \(key) -> \(ip):\(spec.port)")
            } catch {
                log("forward \(key) failed: \(error)")
            }
        }
    }

    /// Sets up DialBack once the guest is ready. mdock-guestd listens for it just before the guest
    /// reports ready; an older guest without it keeps every port on the relay.
    private func startDialBack(_ ip: String) {
        let start = stateLock.withLock { () -> Bool in
            guard dialBack == nil, !dialBackStarting else { return false }
            dialBackStarting = true
            return true
        }
        guard start else { return }
        defer { stateLock.withLock { dialBackStarting = false } }
        for attempt in 0..<10 {
            if attempt > 0 { usleep(200_000) }
            if let dialBack = DialBack.start(guestIP: ip, connect: { [self] in vsockConnect(Guest.dialBackPort) },
                                             hostForward: { [self] fd, port in forwardToMac(fd, port: port, vsock: false) }) {
                stateLock.withLock {
                    self.dialBack = dialBack
                    dialBackFailed = false
                    dialBackRetryAt = 0
                }
                log("published ports and the Docker API reach the guest over the VM's network (dialing back to \(dialBack.address))")
                return
            }
        }
        if stateLock.withLock({ () -> Bool in defer { dialBackFailed = true }; return !dialBackFailed }) {
            log("published ports and the Docker API use vsock: the guest can't dial back over the VM's network")
        }
    }

    /// A connection to `target` in the guest over the VM's network (DialBack.connect). A failure to
    /// dial back is remembered for a minute, so connections don't each wait for it; then it is tried
    /// again (set up again, if mdock-guestd's end went away).
    private func dialBackConnect(_ target: String) -> DialBack.Outcome {
        let (dialBack, restart) = stateLock.withLock { () -> (DialBack?, String?) in
            let now = DispatchTime.now().uptimeNanoseconds
            // A VM on its way down won't dial back; that's no failure to report.
            guard stopStatus == nil, now >= dialBackRetryAt else { return (nil, nil) }
            guard let dialBack = self.dialBack else {
                dialBackRetryAt = now + 60_000_000_000
                return (nil, config.gpu ? nil : guestIP)
            }
            return (dialBack, nil)
        }
        if let restart { Thread.detachNewThread { [self] in startDialBack(restart) } }
        guard let dialBack else { return .unavailable }
        let outcome = dialBack.connect(target)
        switch outcome {
        case .connected:
            if stateLock.withLock({ () -> Bool in defer { dialBackFailed = false }; return dialBackFailed }) {
                log("the guest dials back over the VM's network again")
            }
        case .refused:
            break
        case .unavailable:
            let first = stateLock.withLock { () -> Bool in
                defer {
                    dialBackFailed = true
                    dialBackRetryAt = DispatchTime.now().uptimeNanoseconds + 60_000_000_000
                    if dialBack.isClosed && self.dialBack === dialBack { self.dialBack = nil }
                }
                return !dialBackFailed
            }
            if first { log("the guest didn't dial back (\(target)): published ports and the Docker API use vsock for a minute") }
        }
        return outcome
    }

    /// A connection to a published port in the guest, and whether it is a vsock stream: dialed back
    /// over the VM's network when that works, else over the vsock relay. A port that isn't listening
    /// yet (a container still starting) gets a few tries.
    private func forwardConnect(_ port: UInt16) -> (fd: Int32, vsock: Bool)? {
        for attempt in 0..<5 {
            if attempt > 0 { usleep(UInt32(100_000 * attempt)) }
            switch dialBackConnect("\(port)") {
            case .connected(let fd): return (fd, false)
            case .refused: continue
            case .unavailable: return relayConnect(port, attempts: 5).map { ($0, true) }
            }
        }
        return nil  // nothing listens there
    }

    /// A stream to the guest's Docker API, and whether it is a vsock stream: dialed back over the VM's
    /// network when that works, so `docker save | gzip` or `docker logs | less` just slow dockerd
    /// down; over vsock, a reader that falls 64 MiB behind loses its connection.
    private func dockerConnect() -> (fd: Int32, vsock: Bool)? {
        if case .connected(let fd) = dialBackConnect("unix:/var/run/docker.sock") { return (fd, false) }
        return vsockConnect(Guest.dockerPort).map { ($0, true) }
    }

    private func relayConnect(_ port: UInt16, attempts: Int) -> Int32? {
        for attempt in 0..<attempts {
            if attempt > 0 { usleep(UInt32(100_000 * attempt)) }
            if let fd = relayConnect(port) { return fd }
        }
        return nil
    }

    private func udpRelayConnect(_ port: UInt16) -> Int32? {
        guard let fd = vsockConnect(Guest.udpPort) else { return nil }
        Sockets.writeAll(fd, "\(port)\n")
        return fd
    }

    private func relayConnect(_ port: UInt16) -> Int32? {
        guard let fd = vsockConnect(Guest.relayPort) else { return nil }
        Sockets.writeAll(fd, "\(port)\n")
        return fd
    }

    /// Minimal HTTP/1.0 client for the Docker API, straight over vsock (mdock's own calls don't count
    /// as docker.sock clients, so they never keep the VM from an idle stop).
    func dockerGET(_ path: String) -> Any? {
        guard let fd = vsockConnect(Guest.dockerPort) else { return nil }
        defer { close(fd) }
        Sockets.writeAll(fd, "GET \(path) HTTP/1.0\r\nHost: docker\r\n\r\n")
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            response.append(buffer, count: n)
        }
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return try? JSONSerialization.jsonObject(with: response[split.upperBound...])
    }
}
