import CoreML
import Foundation
import Metal

/// mdock-ml: Apple on-device ML (Foundation Models, Core ML, speech) over HTTP for containers.
/// See accel/CONTRACT.md and accel/ml/README.md.

let version = "0.1.0"
let started = Date()
let coreml = CoreMLService()

func route(_ req: HTTPRequest, _ r: HTTPResponder) throws {
    let parts = req.path.split(separator: "/").map(String.init)
    switch (req.method, req.path) {
    case ("GET", "/health"), ("HEAD", "/health"), ("GET", "/"):
        r.json(200, ["status": "ok", "service": "mdock-ml", "version": version,
                     "uptime_s": Int(Date().timeIntervalSince(started))])
    case ("GET", "/v1/capabilities"):
        r.json(200, capabilities())
    case ("GET", "/v1/models"):
        Chat.models(r)
    case ("POST", "/v1/chat/completions"):
        try Chat.completions(req, r)
    case ("POST", "/v1/audio/transcriptions"):
        try Transcription.handle(req, r)
    default:
        if parts.starts(with: ["v1", "coreml", "models"]) {
            try coreml.route(req, r, Array(parts.dropFirst(3)))
        } else if parts.starts(with: ["v1", "models"]), parts.count == 3, req.method == "GET" {
            Chat.models(r)
        } else {
            throw HTTPError(404, "no route for \(req.method) \(req.path)", code: "not_found")
        }
    }
}

func capabilities() -> [String: Any] {
    let fm = Chat.availability()
    var foundation: [String: Any] = ["available": fm.available, "models": [Chat.generalModel, Chat.taggingModel],
                                     "streaming": true, "json_schema": true, "tools": true]
    if let reason = fm.reason { foundation["reason"] = reason }
    if #available(macOS 26.0, *) { foundation["context_size"] = SystemLanguageModelInfo.contextSize }
    let devices = CoreMLService.devices()
    let ane = devices.first { $0["type"] as? String == "neuralEngine" }
    var host: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
                               "memory_bytes": ProcessInfo.processInfo.physicalMemory,
                               "cpus": ProcessInfo.processInfo.activeProcessorCount]
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    if size > 0 {
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        host["chip"] = String(cString: buffer)
    }
    return [
        "service": "mdock-ml", "version": version, "host": host,
        "foundation_models": foundation,
        "coreml": ["compute_units": ["all", "cpuAndNeuralEngine", "cpuAndGPU", "cpuOnly"],
                   "devices": devices, "neural_engine": ane != nil, "neural_engine_cores": ane?["cores"] ?? 0,
                   "gpu": MTLCreateSystemDefaultDevice()?.name ?? NSNull(),
                   "model_store": Paths.models.path],
        "speech": Transcription.status(),
    ]
}

#if canImport(FoundationModels)
import FoundationModels
@available(macOS 26.0, *)
enum SystemLanguageModelInfo {
    static var contextSize: Int { SystemLanguageModel.default.contextSize }
}
#endif

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: mdock-ml serve [--socket <path>] [--tcp <ipv4>:<port>]
      --socket  unix socket (default ~/.mdock/accel/ml.sock, mode 0600)
      --tcp     test only: also listen on one explicit IPv4 address (never 0.0.0.0)

    """.utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard args.first == "serve" else { usage() }
args.removeFirst()
var socketPath: String?
var tcpSpec: String?
while !args.isEmpty {
    let flag = args.removeFirst()
    switch flag {
    case "--socket":
        if args.isEmpty { usage() }
        socketPath = args.removeFirst()
    case "--tcp":
        if args.isEmpty { usage() }
        tcpSpec = args.removeFirst()
    default: usage()
    }
}
if socketPath == nil && tcpSpec == nil {
    socketPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mdock/accel/ml.sock").path
}
signal(SIGPIPE, SIG_IGN)
try? FileManager.default.createDirectory(at: Paths.models, withIntermediateDirectories: true)

let server = HTTPServer(handler: route)
do {
    if let socketPath {
        let fd = try Listener.unix(socketPath)
        Thread.detachNewThread { server.serve(listener: fd) }
        Log.info("mdock-ml \(version) listening on \(socketPath)")
    }
    if let tcpSpec {
        let fd = try Listener.tcp(tcpSpec)
        Thread.detachNewThread { server.serve(listener: fd) }
        Log.info("mdock-ml listening on tcp \(tcpSpec) (test only)")
    }
} catch let error as HTTPError {
    Log.info("mdock-ml: \(error.message)")
    exit(1)
}
let fm = Chat.availability()
Log.info("foundation models: \(fm.available ? "available" : fm.reason ?? "unavailable")")
dispatchMain()
