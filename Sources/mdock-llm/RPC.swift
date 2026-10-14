import Foundation

/// Exposes ggml's RPC server (Metal backend) on a unix socket.
///
/// ggml-rpc-server serves one client at a time and keeps that client's buffers until it
/// disconnects, so each incoming connection gets its own short-lived ggml-rpc-server on a random
/// loopback port. Clients run concurrently, cannot see each other's buffers, and all GPU memory a
/// client allocated is returned when its connection (and process) ends.
final class RPCService {
    let binary: String
    let cacheDirectory: URL?
    let maxSessions: Int
    let memoryLimit: Int64
    let children: ChildRegistry
    private let lock = NSLock()
    private var sessions = 0

    init(binary: String, cacheDirectory: URL?, maxSessions: Int, memoryLimit: Int64, children: ChildRegistry) {
        self.binary = binary
        self.cacheDirectory = cacheDirectory
        self.maxSessions = maxSessions
        self.memoryLimit = memoryLimit
        self.children = children
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    func handle(_ client: Int32) {
        let admitted: Bool = lock.withLock {
            if sessions >= maxSessions { return false }
            sessions += 1
            return true
        }
        guard admitted else {
            log("rpc: refusing connection, \(maxSessions) sessions already active (--rpc-sessions)")
            close(client)
            return
        }
        func finish() { lock.withLock { sessions -= 1 } }

        let process: Process
        let upstream: Int32
        do {
            (process, upstream) = try launch()
        } catch {
            log("rpc: \(error)")
            close(client)
            finish()
            return
        }
        let pid = process.processIdentifier
        log("rpc: session started (ggml-rpc-server pid \(pid))")
        Sockets.splice(client, upstream) { [children] in
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
            children.remove(pid)
            log("rpc: session ended (pid \(pid))")
            finish()
            self.pruneCache()
        }
    }

    /// Keeps the tensor cache under 16 GiB by deleting the least recently modified files.
    private func pruneCache(limit: Int64 = 16 << 30) {
        guard let cacheDirectory else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: keys)) ?? [])
            .compactMap { url -> (URL, Int64, Date)? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.2 < $1.2 }
        var total = files.reduce(0) { $0 + $1.1 }
        for (url, size, _) in files where total > limit {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }

    /// Starts ggml-rpc-server and returns it with a connection to it. The first successful
    /// connect is the session itself, so no probe connection reaches the server.
    private func launch() throws -> (Process, Int32) {
        let port = try Sockets.freeLoopbackPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var args = ["--host", "127.0.0.1", "--port", String(port)]
        var environment = ProcessInfo.processInfo.environment
        // Enforced by patches/rpc-server-alloc-limit.patch: allocations past this fail, and the
        // device reports this much memory so clients size their offload to it.
        environment["GGML_RPC_MAX_ALLOC_MB"] = String(memoryLimit >> 20)
        if let cacheDirectory {
            args.append("--cache")
            environment["LLAMA_CACHE"] = cacheDirectory.path
        }
        process.arguments = args
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let tail = LogTail()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            tail.append(data, prefix: "[rpc \(port)] ")
        }
        try process.run()
        children.add(process.processIdentifier)
        let started = Date()
        while Date().timeIntervalSince(started) < 20 {
            if let fd = Sockets.tcpConnect(host: "127.0.0.1", port: port) { return (process, fd) }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.terminate()
        children.remove(process.processIdentifier)
        throw LLMError(description: "ggml-rpc-server did not start: \(tail.text)")
    }
}
