import Foundation
import Metal

let usage = """
mdock-llm — native Metal llama.cpp for mdock containers.

Usage:
  mdock-llm serve --socket <path> [--rpc-socket <path>] [options]

  An OpenAI-compatible HTTP API (/v1/models, /v1/chat/completions, /v1/completions,
  /v1/embeddings) and Ollama-compatible routes (/api/tags, /api/chat, /api/generate, /api/embed)
  on a unix socket. One llama-server per model is started on demand on 127.0.0.1 and stopped
  when idle. --rpc-socket also serves ggml RPC (Metal) for `llama-* --rpc host:port` clients.

Options:
  --models <dir>          GGUF directory (default ~/.mdock/models). Model ids are file names
                          without .gguf; `owner/repo:file.gguf` or `owner/repo[:QUANT]` downloads
                          from Hugging Face on first use (HF_TOKEN is honoured)
  --ctx-size <n>          Context per model (default 8192, capped at the model's own)
  --parallel <n>          Concurrent sequences per model (default 4)
  --idle <seconds>        Unload a model after this long without requests (default 300)
  --max-memory <GiB>      Budget for all loaded models (default 40% of RAM)
  --max-models <n>        Most models loaded at once (default 3)
  --rpc-sessions <n>      Most concurrent RPC clients (default 2)
  --rpc-max-memory <GiB>  GPU memory one RPC client may allocate (default: same as --max-memory)
  --rpc-cache             Cache uploaded weights on disk (~/.mdock/cache/llm-rpc, capped at 16 GiB)
                          so repeat model loads over RPC skip the upload. Off by default: the
                          cache is shared by all clients and keyed by a non-cryptographic hash
  --llama-prefix <dir>    Where bin/llama-server lives (default: found automatically)
  --server-arg <arg>      Extra llama-server argument (repeatable)
  --tcp <ip:port>         Test only: also serve the HTTP API on this address
  --rpc-tcp <ip:port>     Test only: also serve RPC on this address
"""

struct Options {
    var socket: String?
    var rpcSocket: String?
    var tcp: (String, UInt16)?
    var rpcTCP: (String, UInt16)?
    var models = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mdock/models").path
    var prefix: String?
    var rpcCache = false
    var rpcSessions = 2
    var pool = PoolSettings()
    var maxMemoryGiB: Double?
    var rpcMaxMemoryGiB: Double?
}

func parseAddress(_ text: String) throws -> (String, UInt16) {
    let parts = text.split(separator: ":")
    guard parts.count == 2, let port = UInt16(parts[1]) else {
        throw LLMError(description: "expected ip:port, got \(text)")
    }
    let host = String(parts[0])
    if host == "0.0.0.0" {
        throw LLMError(description: "refusing to listen on all interfaces; give a specific address")
    }
    return (host, port)
}

func parseOptions(_ args: [String]) throws -> Options {
    var options = Options()
    var iterator = args.makeIterator()
    func value(_ flag: String) throws -> String {
        guard let next = iterator.next() else { throw LLMError(description: "\(flag) needs a value") }
        return next
    }
    func number(_ flag: String) throws -> Int {
        guard let n = Int(try value(flag)), n > 0 else { throw LLMError(description: "\(flag) needs a positive number") }
        return n
    }
    while let arg = iterator.next() {
        switch arg {
        case "--socket": options.socket = try value(arg)
        case "--rpc-socket": options.rpcSocket = try value(arg)
        case "--tcp": options.tcp = try parseAddress(try value(arg))
        case "--rpc-tcp": options.rpcTCP = try parseAddress(try value(arg))
        case "--models": options.models = (try value(arg) as NSString).expandingTildeInPath
        case "--llama-prefix": options.prefix = (try value(arg) as NSString).expandingTildeInPath
        case "--ctx-size": options.pool.contextSize = try number(arg)
        case "--parallel": options.pool.parallel = try number(arg)
        case "--idle": options.pool.idleSeconds = TimeInterval(try number(arg))
        case "--max-models": options.pool.maxModels = try number(arg)
        case "--rpc-sessions": options.rpcSessions = try number(arg)
        case "--max-memory":
            guard let gib = Double(try value(arg)), gib > 0 else { throw LLMError(description: "--max-memory needs GiB") }
            options.maxMemoryGiB = gib
        case "--rpc-cache": options.rpcCache = true
        case "--rpc-max-memory":
            guard let gib = Double(try value(arg)), gib > 0 else { throw LLMError(description: "--rpc-max-memory needs GiB") }
            options.rpcMaxMemoryGiB = gib
        case "--server-arg": options.pool.extraArgs.append(try value(arg))
        default: throw LLMError(description: "unknown option \(arg)")
        }
    }
    return options
}

func serve(_ options: Options) throws {
    signal(SIGPIPE, SIG_IGN)
    guard options.socket != nil || options.tcp != nil else {
        throw LLMError(description: "serve needs --socket (or --tcp for testing)")
    }
    let state = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mdock")
    let accel = state.appendingPathComponent("accel")
    try FileManager.default.createDirectory(at: accel, withIntermediateDirectories: true)

    var settings = options.pool
    let physical = Int64(ProcessInfo.processInfo.physicalMemory)
    // The mdock VM can take half the RAM and macOS needs the rest, so models get 40% by default,
    // and never more than Metal's recommended working set.
    var budget = options.maxMemoryGiB.map { Int64($0 * Double(1 << 30)) } ?? physical * 2 / 5
    if let device = MTLCreateSystemDefaultDevice() {
        budget = min(budget, Int64(device.recommendedMaxWorkingSetSize))
    }
    settings.memoryBudget = budget

    let toolchain = try Toolchain.locate(prefix: options.prefix)
    // One registry per listening socket, so a second (test) instance never touches the first's children.
    let registryName = (options.socket ?? options.tcp.map { "\($0.0)-\($0.1)" } ?? "tcp")
        .replacingOccurrences(of: "/", with: "_")
    let children = ChildRegistry(file: accel.appendingPathComponent("mdock-llm\(registryName).children"))
    let store = ModelStore(directory: URL(fileURLWithPath: options.models))
    let pool = Pool(toolchain: toolchain, store: store, settings: settings, children: children)
    let api = API(pool: pool, store: store)
    let cancel = Cancel()
    log("llama-server: \(toolchain.llamaServer); models: \(store.directory.path); budget \(gib(budget)) GiB, "
        + "ctx \(settings.contextSize), idle \(Int(settings.idleSeconds)) s")

    if let path = options.socket {
        Sockets.acceptLoop(try Sockets.unixListen(path), cancel: cancel, handler: api.handle)
        log("HTTP on \(path)")
    }
    if let (host, port) = options.tcp {
        Sockets.acceptLoop(try Sockets.tcpListen(host: host, port: port), cancel: cancel, handler: api.handle)
        log("HTTP on \(host):\(port) (test listener)")
    }
    if options.rpcSocket != nil || options.rpcTCP != nil {
        guard let binary = toolchain.rpcServer else {
            throw LLMError(description: "ggml-rpc-server not found (run accel/llm/build.sh)")
        }
        let cache = options.rpcCache ? state.appendingPathComponent("cache/llm-rpc") : nil
        let rpcLimit = options.rpcMaxMemoryGiB.map { Int64($0 * Double(1 << 30)) } ?? budget
        let rpc = RPCService(binary: binary, cacheDirectory: cache, maxSessions: options.rpcSessions,
                             memoryLimit: rpcLimit, children: children)
        log("RPC: up to \(options.rpcSessions) sessions, \(gib(rpcLimit)) GiB each, cache \(cache?.path ?? "off")")
        if let path = options.rpcSocket {
            Sockets.acceptLoop(try Sockets.unixListen(path), cancel: cancel, handler: rpc.handle)
            log("RPC on \(path)")
        }
        if let (host, port) = options.rpcTCP {
            Sockets.acceptLoop(try Sockets.tcpListen(host: host, port: port), cancel: cancel, handler: rpc.handle)
            log("RPC on \(host):\(port) (test listener)")
        }
    }

    var sources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            log("shutting down")
            cancel.set()
            pool.stopAll()
            for pid in children.all() { kill(pid, SIGTERM) }
            for path in [options.socket, options.rpcSocket].compactMap({ $0 }) { unlink(path) }
            Thread.sleep(forTimeInterval: 0.5)
            for pid in children.all() { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: children.file)
            exit(0)
        }
        source.resume()
        sources.append(source)
    }
    withExtendedLifetime(sources) { dispatchMain() }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "serve":
    do {
        try serve(try parseOptions(Array(arguments.dropFirst())))
    } catch {
        FileHandle.standardError.write(Data("mdock-llm: \(error)\n".utf8))
        exit(1)
    }
case "-h", "--help", "help", nil:
    print(usage)
default:
    FileHandle.standardError.write(Data("mdock-llm: unknown command \(arguments[0])\n\n\(usage)\n".utf8))
    exit(2)
}
