import Foundation

/// Where the native llama.cpp binaries live.
struct Toolchain {
    var llamaServer: String
    var rpcServer: String?

    /// MDOCK_LLM_PREFIX, then next to this binary (app bundle), then the source tree's
    /// accel/llm/prefix (development: .build-mdock-llm/release/mdock-llm), then Homebrew.
    static func locate(prefix: String?) throws -> Toolchain {
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().deletingLastPathComponent()
        var dirs: [URL] = []
        if let prefix { dirs.append(URL(fileURLWithPath: prefix).appendingPathComponent("bin")) }
        if let env = ProcessInfo.processInfo.environment["MDOCK_LLM_PREFIX"] {
            dirs.append(URL(fileURLWithPath: env).appendingPathComponent("bin"))
        }
        dirs.append(exe)
        // .build-mdock-llm/release is a symlink to .build-mdock-llm/arm64-apple-macosx/release.
        var parent = exe
        for _ in 0..<4 {
            parent = parent.deletingLastPathComponent()
            dirs.append(parent.appendingPathComponent("accel/llm/prefix/bin"))
        }
        dirs.append(URL(fileURLWithPath: "/opt/homebrew/bin"))
        // Take both tools from the first directory that has llama-server, so they match.
        for dir in dirs where FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("llama-server").path) {
            let rpc = ["ggml-rpc-server", "rpc-server"].map { dir.appendingPathComponent($0).path }
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            return Toolchain(llamaServer: dir.appendingPathComponent("llama-server").path, rpcServer: rpc)
        }
        throw LLMError(description: "llama-server not found (run accel/llm/build.sh); searched \(dirs.map(\.path))")
    }
}

/// Tracks child processes in a pid file so a restart after a crash can reap orphans.
final class ChildRegistry {
    let file: URL
    private let lock = NSLock()
    private var pids: Set<pid_t> = []

    init(file: URL) {
        self.file = file
        reapStale()
    }

    private func reapStale() {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        for pid in text.split(whereSeparator: \.isNewline).compactMap({ pid_t($0) }) where pid > 1 {
            var buffer = [CChar](repeating: 0, count: 4 * 1024)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            // Only orphans (re-parented to launchd): a live mdock-llm still owns its children.
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid == 1 else { continue }
            if path.hasSuffix("/llama-server") || path.hasSuffix("rpc-server") {
                log("killing orphaned \(path) (pid \(pid))")
                kill(pid, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(at: file)
    }

    func add(_ pid: pid_t) { lock.withLock { pids.insert(pid); save() } }
    func remove(_ pid: pid_t) { lock.withLock { pids.remove(pid); save() } }
    func all() -> [pid_t] { lock.withLock { Array(pids) } }

    private func save() {
        let text = pids.map(String.init).joined(separator: "\n")
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }
}

enum InstanceKind: String {
    case generate
    case embed
}

/// One llama-server process serving one model on 127.0.0.1:port.
final class Instance {
    let key: String
    let model: LocalModel
    let kind: InstanceKind
    let port: UInt16
    let memory: Int64
    let process: Process
    let ready = DispatchGroup()
    var failure: LLMError?
    var inflight = 0
    var lastUsed = Date()

    init(key: String, model: LocalModel, kind: InstanceKind, port: UInt16, memory: Int64, process: Process) {
        self.key = key
        self.model = model
        self.kind = kind
        self.port = port
        self.memory = memory
        self.process = process
    }
}

struct PoolSettings {
    var contextSize = 8192
    var idleSeconds: TimeInterval = 300
    var memoryBudget: Int64 = 0
    var maxModels = 3
    var parallel = 4
    var extraArgs: [String] = []
}

/// Starts llama-server per model on demand, keeps loaded models within a memory budget, and
/// unloads idle ones.
final class Pool {
    let toolchain: Toolchain
    let store: ModelStore
    let settings: PoolSettings
    let children: ChildRegistry
    private let lock = NSCondition()
    private var instances: [String: Instance] = [:]

    init(toolchain: Toolchain, store: ModelStore, settings: PoolSettings, children: ChildRegistry) {
        self.toolchain = toolchain
        self.store = store
        self.settings = settings
        self.children = children
        Thread.detachNewThread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 5)
                reapIdle()
            }
        }
    }

    var loaded: [Instance] { lock.withLock { Array(instances.values) } }

    /// Estimated resident memory: weights + KV cache + compute buffers.
    func estimate(_ model: LocalModel, kind: InstanceKind, info: GGUFInfo?) -> (memory: Int64, context: Int) {
        var context = settings.contextSize
        if let trained = info?.contextLength, trained > 0 { context = min(context, trained) }
        let kv = Int64(info?.kvBytesPerToken ?? 0) * Int64(context)
        let compute: Int64 = kind == .embed ? 512 << 20 : 384 << 20
        return (model.size + kv + compute, context)
    }

    /// Returns a ready instance with one request accounted to it; call `release` when done.
    func acquire(_ modelID: String, kind: InstanceKind) throws -> Instance {
        let model = try store.resolve(modelID)
        let key = "\(kind.rawValue):\(model.id)"
        let deadline = Date().addingTimeInterval(600)
        lock.lock()
        while true {
            if let existing = instances[key] {
                existing.inflight += 1
                existing.lastUsed = Date()
                lock.unlock()
                existing.ready.wait()
                if let failure = existing.failure {
                    release(existing)
                    throw failure
                }
                return existing
            }
            let info = GGUFInfo.read(model.url)
            let (memory, context) = estimate(model, kind: kind, info: info)
            if memory > settings.memoryBudget {
                lock.unlock()
                throw LLMError(description: "\(model.id) needs about \(gib(memory)) GiB, more than the "
                    + "\(gib(settings.memoryBudget)) GiB budget (mdock-llm serve --max-memory)", status: 507)
            }
            if canFit(memory) || evictIdle(toFit: memory) {
                let instance: Instance
                do {
                    instance = try start(model, kind: kind, key: key, memory: memory, context: context, info: info)
                } catch {
                    lock.unlock()
                    throw error
                }
                instances[key] = instance
                instance.inflight = 1
                lock.unlock()
                instance.ready.wait()
                if let failure = instance.failure {
                    release(instance)
                    throw failure
                }
                return instance
            }
            // Everything loaded is busy: wait for a request to finish.
            guard lock.wait(until: min(deadline, Date().addingTimeInterval(5))) || Date() < deadline else {
                lock.unlock()
                throw LLMError(description: "no memory for \(model.id): loaded models are busy", status: 503)
            }
        }
    }

    func release(_ instance: Instance) {
        lock.withLock {
            instance.inflight -= 1
            instance.lastUsed = Date()
            if instance.failure != nil && instance.inflight == 0 && instances[instance.key] === instance {
                instances[instance.key] = nil
            }
            lock.broadcast()
        }
    }

    /// Called when a connection to the instance fails; drops it if the process is gone.
    func checkAlive(_ instance: Instance) {
        lock.withLock {
            if !instance.process.isRunning, instances[instance.key] === instance {
                instances[instance.key] = nil
                lock.broadcast()
            }
        }
    }

    private func used() -> Int64 { instances.values.reduce(0) { $0 + $1.memory } }

    private func canFit(_ memory: Int64) -> Bool {
        instances.count < settings.maxModels && used() + memory <= settings.memoryBudget
    }

    /// Stops least-recently-used idle instances until `memory` fits. Caller holds the lock.
    private func evictIdle(toFit memory: Int64) -> Bool {
        let idle = instances.values.filter { $0.inflight == 0 }.sorted { $0.lastUsed < $1.lastUsed }
        for victim in idle {
            if canFit(memory) { break }
            log("unloading \(victim.key) to make room")
            stop(victim)
        }
        return canFit(memory)
    }

    private func reapIdle() {
        lock.withLock {
            let now = Date()
            for instance in instances.values where instance.inflight == 0 {
                if !instance.process.isRunning {
                    instances[instance.key] = nil
                } else if now.timeIntervalSince(instance.lastUsed) > settings.idleSeconds {
                    log("unloading idle \(instance.key)")
                    stop(instance)
                }
            }
            lock.broadcast()
        }
    }

    /// Caller holds the lock.
    private func stop(_ instance: Instance) {
        instances[instance.key] = nil
        let process = instance.process
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func stopAll() {
        lock.withLock {
            for instance in instances.values { instance.process.terminate() }
            instances.removeAll()
        }
    }

    /// Caller holds the lock. Launches the process; readiness is signalled on `instance.ready`.
    private func start(_ model: LocalModel, kind: InstanceKind, key: String, memory: Int64, context: Int,
                       info: GGUFInfo?) throws -> Instance {
        let port = try Sockets.freeLoopbackPort()
        var args = [
            "--model", model.url.path,
            "--alias", model.id,
            "--host", "127.0.0.1", "--port", String(port),
            "--ctx-size", String(context),
            "--n-gpu-layers", "999",
            "--no-webui",
            // llama-server keeps up to 8 GiB of prompt cache in RAM by default; too much here.
            "--cache-ram", "256",
            "--log-colors", "off",
        ]
        switch kind {
        case .generate:
            // One KV pool shared by all slots, so a single request can use the whole context.
            args += ["--parallel", String(settings.parallel), "--kv-unified", "--jinja"]
        case .embed:
            args += ["--embeddings", "--ubatch-size", "2048", "--batch-size", "2048", "--parallel", "2", "--kv-unified"]
            if !(info?.hasPoolingType ?? false) { args += ["--pooling", "mean"] }
        }
        args += settings.extraArgs

        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolchain.llamaServer)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let instance = Instance(key: key, model: model, kind: kind, port: port, memory: memory, process: process)
        instance.ready.enter()

        // Keep the last lines of output for error messages; mirror everything to our log.
        let tail = LogTail()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            tail.append(data, prefix: "[\(key)] ")
        }
        process.terminationHandler = { [weak self] process in
            log("\(key) exited (status \(process.terminationStatus))")
            self?.children.remove(process.processIdentifier)
            self?.checkAlive(instance)
        }
        log("loading \(key) on 127.0.0.1:\(port) (~\(gib(memory)) GiB, ctx \(context))")
        try process.run()
        children.add(process.processIdentifier)

        Thread.detachNewThread {
            let started = Date()
            while Date().timeIntervalSince(started) < 300 {
                if !process.isRunning {
                    instance.failure = LLMError(description: "llama-server for \(model.id) exited: \(tail.text)", status: 500)
                    break
                }
                if Self.healthy(port: port) {
                    log("\(key) ready in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if instance.failure == nil && !Self.healthy(port: port) {
                instance.failure = LLMError(description: "llama-server for \(model.id) did not become ready", status: 504)
                process.terminate()
            }
            instance.ready.leave()
        }
        return instance
    }

    static func healthy(port: UInt16) -> Bool {
        guard let fd = Sockets.tcpConnect(host: "127.0.0.1", port: port) else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        Sockets.writeAll(fd, "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        let line = Reader(fd).readLine() ?? ""
        return line.hasPrefix("HTTP/1.1 200")
    }
}

final class LogTail {
    private let lock = NSLock()
    private var lines: [String] = []
    private var partial = ""

    func append(_ data: Data, prefix: String) {
        lock.withLock {
            let text = partial + String(decoding: data, as: UTF8.self)
            var pieces = text.components(separatedBy: "\n")
            partial = pieces.removeLast()
            for line in pieces where !line.isEmpty {
                FileHandle.standardError.write(Data((prefix + line + "\n").utf8))
                lines.append(line)
            }
            if lines.count > 20 { lines.removeFirst(lines.count - 20) }
        }
    }

    var text: String { lock.withLock { lines.suffix(6).joined(separator: " | ") } }
}

func gib(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / Double(1 << 30)) }
