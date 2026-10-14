import Foundation

/// Accelerator bridge (accel/CONTRACT.md): guest vsock ports are routed to native macOS services,
/// which are started lazily on first use and stopped with the daemon.
enum Accel {
    struct Service {
        var name: String
        var port: UInt32
        var socket: URL
        /// Executable that serves `socket`; nil when the daemon serves it itself.
        var binary: String?
    }

    static let dir = Paths.url("accel")
    static let guestDir = dir.appendingPathComponent("guest")

    static let services: [Service] = [
        Service(name: "media", port: 1026, socket: dir.appendingPathComponent("media.sock"), binary: nil),
        Service(name: "vt", port: 1027, socket: dir.appendingPathComponent("vt.sock"), binary: "mdock-vt"),
        Service(name: "ml", port: 1028, socket: dir.appendingPathComponent("ml.sock"), binary: "mdock-ml"),
        Service(name: "llm", port: 1029, socket: dir.appendingPathComponent("llm.sock"), binary: "mdock-llm"),
        Service(name: "llm-rpc", port: 1030, socket: dir.appendingPathComponent("llm-rpc.sock"), binary: "mdock-llm"),
    ]

    static func service(port: UInt32) -> Service? { services.first { $0.port == port } }

    /// Unix socket the GPU engine's libkrun connects to for a guest->host accel port.
    static func krunSocket(_ port: UInt32) -> String { Paths.url("krun-\(port).sock").path }

    /// Next to the mdock binary (app bundle / install), or a per-service build dir in the repo.
    static func locate(_ binary: String) -> String? {
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
        // A per-service build in the repo wins over a sibling (which in .build/ may be a stale stub).
        var candidates: [URL] = []
        var dir = exe.deletingLastPathComponent()
        while dir.path != "/" {
            candidates.append(dir.appendingPathComponent(".build-\(binary)/release/\(binary)"))
            dir = dir.deletingLastPathComponent()
        }
        candidates.append(exe.deletingLastPathComponent().appendingPathComponent(binary))
        return candidates.map(\.path).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Host ffmpeg/ffprobe for the media-exec service: our jellyfin-ffmpeg build, else Homebrew's.
    static func mediaTool(_ name: String) -> String? {
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
        var candidates = [exe.deletingLastPathComponent().appendingPathComponent("media/bin/\(name)")]
        var dir = exe.deletingLastPathComponent()
        while dir.path != "/" {
            candidates.append(dir.appendingPathComponent("accel/media/prefix/bin/\(name)"))
            dir = dir.deletingLastPathComponent()
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"))
        return candidates.map(\.path).first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Starts accel services on demand and connects guest streams to them.
final class AccelRouter {
    private let lock = NSLock()
    private var running: [String: pid_t] = [:]
    private let media = MediaExecServer()

    init() {
        try? FileManager.default.createDirectory(at: Accel.guestDir, withIntermediateDirectories: true)
        // VA-API frame files: bind-mounted into containers by CDI, so it must exist before they start.
        try? FileManager.default.createDirectory(at: Accel.dir.appendingPathComponent("frames"), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o711])
    }

    /// Takes ownership of `fd`, a stream the guest opened on `port`.
    func handle(_ fd: Int32, port: UInt32) {
        guard let service = Accel.service(port: port) else { close(fd); return }
        Thread.detachNewThread { [self] in
            if service.binary == nil {
                media.serve(fd)
                return
            }
            guard let upstream = connect(service) else {
                log("accel: \(service.name) unavailable")
                close(fd)
                return
            }
            Sockets.splice(fd, upstream)
        }
    }

    private func connect(_ service: Service) -> Int32? {
        if let fd = Sockets.unixConnect(service.socket.path) { return fd }
        guard start(service) else { return nil }
        for _ in 0..<200 {
            if let fd = Sockets.unixConnect(service.socket.path) { return fd }
            usleep(50_000)
        }
        return nil
    }

    typealias Service = Accel.Service

    /// Launches the service's binary unless it is already running. mdock-llm serves both llm sockets.
    private func start(_ service: Service) -> Bool {
        guard let binary = service.binary, let path = Accel.locate(binary) else {
            log("accel: \(service.binary ?? service.name) is not built")
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        if let pid = running[binary], isAlive(pid) { return true }
        var args = ["serve"]
        if binary == "mdock-llm" {
            let llm = Accel.services.first { $0.name == "llm" }!, rpc = Accel.services.first { $0.name == "llm-rpc" }!
            args += ["--socket", llm.socket.path, "--rpc-socket", rpc.socket.path]
        } else {
            args += ["--socket", service.socket.path]
        }
        let logURL = Accel.dir.appendingPathComponent("\(binary).log")
        rotateLog(logURL)
        let logFD = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        defer { close(logFD) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, logFD, 1)
        posix_spawn_file_actions_adddup2(&actions, logFD, 2)
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        guard withChildSpawnAttributes({ posix_spawn(&pid, path, &actions, $0, argv, environ) }) == 0 else { return false }
        running[binary] = pid
        log("accel: started \(binary) (pid \(pid))")
        return true
    }

    /// Per-service state for `mdock status` and the desktop app.
    func status() -> [[String: Any]] {
        lock.withLock {
            Accel.services.map { s in
                let binary = s.binary ?? "mdock"
                let built = s.binary == nil ? Accel.mediaTool("ffmpeg") != nil : Accel.locate(binary) != nil
                let running = s.binary == nil ? true : running[binary].map(isAlive) ?? false
                return ["name": s.name, "port": Int(s.port), "built": built, "running": running]
            }
        }
    }

    /// Reaps the child if it exited (kill(pid, 0) succeeds on zombies, so it can't be used).
    private func isAlive(_ pid: pid_t) -> Bool {
        waitpid(pid, nil, WNOHANG) == 0
    }

    func stopAll() {
        lock.withLock { for pid in running.values { kill(pid, SIGTERM) } }
    }
}

/// media-exec: runs ffmpeg/ffprobe on the Mac for a container (see accel/media/shim.c).
///
/// Request: one JSON line `{"tool":"ffmpeg","args":[...],"cwd":"/Users/..."}`, then frames of
/// `[type u8][length u32 BE][payload]`. Client->host: 0 stdin data, 1 stdin EOF, 2 signal (1 byte).
/// Host->client: 3 stdout, 4 stderr, 5 exit (int32 BE: exit code, or -signal).
/// If the client disconnects, the process is killed.
final class MediaExecServer {
    private struct Request: Decodable {
        var tool: String
        var args: [String]
        var cwd: String?
    }

    func serve(_ fd: Int32) {
        defer { close(fd) }
        guard let line = Sockets.readLine(fd, limit: 4 << 20),
              let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)),
              ["ffmpeg", "ffprobe"].contains(request.tool),
              let tool = Accel.mediaTool(request.tool) else {
            log("media: bad request or no host ffmpeg")
            return
        }
        let writeLock = NSLock()
        func send(_ type: UInt8, _ payload: UnsafeRawBufferPointer) {
            var header = [type, 0, 0, 0, 0]
            let n = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: n) { for i in 0..<4 { header[1 + i] = $0[i] } }
            writeLock.withLock {
                _ = header.withUnsafeBytes { writeFully(fd, $0) }
                if payload.count > 0 { _ = writeFully(fd, payload) }
            }
        }

        var stdinPipe: [Int32] = [0, 0], stdoutPipe: [Int32] = [0, 0], stderrPipe: [Int32] = [0, 0]
        pipe(&stdinPipe); pipe(&stdoutPipe); pipe(&stderrPipe)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], 2)
        for p in [stdinPipe, stdoutPipe, stderrPipe] { posix_spawn_file_actions_addclose(&actions, p[0]); posix_spawn_file_actions_addclose(&actions, p[1]) }
        if let cwd = request.cwd, FileManager.default.fileExists(atPath: cwd) {
            posix_spawn_file_actions_addchdir_np(&actions, cwd)
        }
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = ([tool] + request.args).map { strdup($0) } + [nil]
        let rc = withChildSpawnAttributes { posix_spawn(&pid, tool, &actions, $0, argv, environ) }
        posix_spawn_file_actions_destroy(&actions)
        argv.forEach { free($0) }
        close(stdinPipe[0]); close(stdoutPipe[1]); close(stderrPipe[1])
        guard rc == 0 else {
            var code = Int32(127).bigEndian
            withUnsafeBytes(of: &code) { send(5, $0) }
            return
        }

        let group = DispatchGroup()
        for (pipeFD, type) in [(stdoutPipe[0], UInt8(3)), (stderrPipe[0], UInt8(4))] {
            group.enter()
            Thread.detachNewThread {
                defer { close(pipeFD); group.leave() }
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 18, alignment: 16)
                defer { buffer.deallocate() }
                while true {
                    let n = read(pipeFD, buffer, 1 << 18)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { return }
                    send(type, UnsafeRawBufferPointer(start: buffer, count: n))
                }
            }
        }

        // Client frames: stdin and signals. Disconnect kills the process. stdin has its own writer
        // behind a queue, so this thread keeps draining the vsock socket even while the tool reads
        // slowly: an unread vsock socket stalls every vsock connection (see Sockets.splice).
        let stdinWrite = stdinPipe[1]
        let stdinQueue = ByteQueue(limit: 64 << 20)
        Thread.detachNewThread {
            while let chunk = stdinQueue.pop() {
                let written = writeFully(stdinWrite, UnsafeRawBufferPointer(start: chunk.buffer + chunk.start, count: chunk.count))
                stdinQueue.recycle(chunk.buffer)
                stdinQueue.done()
                guard written else {
                    stdinQueue.abort()  // the tool closed its stdin
                    break
                }
            }
            close(stdinWrite)
        }
        Thread.detachNewThread {
            var stdinOpen = true
            while true {
                var header = [UInt8](repeating: 0, count: 5)
                guard readFully(fd, &header) else { break }
                let length = Int(header[1]) << 24 | Int(header[2]) << 16 | Int(header[3]) << 8 | Int(header[4])
                var payload = [UInt8](repeating: 0, count: length)
                guard length == 0 || readFully(fd, &payload) else { break }
                switch header[0] {
                case 0 where stdinOpen: if !stdinQueue.push(Data(payload)) { stdinOpen = false }
                case 1 where stdinOpen: stdinQueue.finish(); stdinOpen = false
                case 2: if let sig = payload.first { kill(pid, Int32(sig)) }
                default: break
                }
            }
            if stdinOpen { stdinQueue.finish() }
            kill(pid, SIGKILL)
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        group.wait()
        let signaled = (status & 0x7f) != 0 && (status & 0x7f) != 0x7f
        var code = (signaled ? -(status & 0x7f) : (status >> 8) & 0xff).bigEndian
        withUnsafeBytes(of: &code) { send(5, $0) }
        shutdown(fd, SHUT_WR)
    }
}

@discardableResult
private func writeFully(_ fd: Int32, _ data: UnsafeRawBufferPointer) -> Bool {
    var offset = 0
    while offset < data.count {
        let n = write(fd, data.baseAddress! + offset, data.count - offset)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return false }
        offset += n
    }
    return true
}

private func readFully(_ fd: Int32, _ buffer: inout [UInt8]) -> Bool {
    var offset = 0
    while offset < buffer.count {
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, $0.count - offset) }
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return false }
        offset += n
    }
    return true
}
