import Foundation

/// Talks to the mdock daemon (control socket), the Docker API (docker.sock) and the mdock CLI.
enum Backend {
    static let state = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mdock")
    static let controlSocket = state.appendingPathComponent("control.sock").path
    static let dockerSocket = state.appendingPathComponent("docker.sock").path
    static let configFile = state.appendingPathComponent("config.json")
    static let idleMarker = state.appendingPathComponent("idle-stopped").path

    /// Stopped by idle stop: launchd starts the VM again on the next docker command.
    static var idleStopped: Bool { FileManager.default.fileExists(atPath: idleMarker) }

    /// The CLI: bundled next to the app's executable, or the development build.
    static var cli: String? {
        let exeDir = URL(fileURLWithPath: Bundle.main.executablePath ?? "").deletingLastPathComponent()
        let candidates = [
            exeDir.appendingPathComponent("mdock").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("mdock/.build/release/mdock").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Unix sockets

    static func connect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes.prefix(raw.count - 1))
            raw[min(bytes.count, raw.count - 1)] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if ok != 0 { close(fd); return nil }
        return fd
    }

    static func exchange(_ path: String, _ request: Data) -> Data? {
        guard let fd = connect(path) else { return nil }
        defer { close(fd) }
        var sent = 0
        while sent < request.count {
            let n = request.withUnsafeBytes { write(fd, $0.baseAddress! + sent, request.count - sent) }
            if n <= 0 { return nil }
            sent += n
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            response.append(buffer, count: n)
        }
        return response
    }

    // MARK: Daemon

    static func status() -> DaemonStatus? {
        guard let data = exchange(controlSocket, Data("status\n".utf8)) else { return nil }
        return try? JSONDecoder().decode(DaemonStatus.self, from: data)
    }

    static func config() -> [String: Any] {
        guard let data = try? Data(contentsOf: configFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    // MARK: Docker API (HTTP/1.0 over the unix socket: no chunked encoding)

    struct HTTPResponse {
        var status: Int
        var body: Data
    }

    static func docker(_ method: String, _ path: String) -> HTTPResponse? {
        let request = "\(method) \(path) HTTP/1.0\r\nHost: docker\r\nContent-Length: 0\r\n\r\n"
        guard let raw = exchange(dockerSocket, Data(request.utf8)),
              let split = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: raw[..<split.lowerBound], as: UTF8.self)
        let code = head.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        return HTTPResponse(status: code, body: raw[split.upperBound...])
    }

    static func dockerJSON<T: Decodable>(_ path: String, as: T.Type) -> T? {
        guard let response = docker("GET", path), response.status == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: response.body)
    }

    /// Container logs; non-TTY streams are multiplexed with 8-byte frame headers.
    static func logs(_ id: String) -> String {
        guard let response = docker("GET", "/containers/\(id)/logs?stdout=1&stderr=1&tail=1000&timestamps=0") else {
            return "Could not read logs"
        }
        let bytes = [UInt8](response.body)
        guard bytes.count >= 8, bytes[0] <= 2, bytes[1] == 0, bytes[2] == 0, bytes[3] == 0 else {
            return String(decoding: bytes, as: UTF8.self)
        }
        var text = [UInt8]()
        var i = 0
        while i + 8 <= bytes.count {
            let size = Int(bytes[i + 4]) << 24 | Int(bytes[i + 5]) << 16 | Int(bytes[i + 6]) << 8 | Int(bytes[i + 7])
            let end = min(bytes.count, i + 8 + size)
            text += bytes[(i + 8)..<end]
            i = end
        }
        return String(decoding: text, as: UTF8.self)
    }

    // MARK: CLI

    @discardableResult
    static func runCLI(_ args: [String]) async -> (ok: Bool, output: String) {
        guard let cli else { return (false, "mdock CLI not found") }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { p in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: (p.terminationStatus == 0, output.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            do { try process.run() } catch { continuation.resume(returning: (false, "\(error)")) }
        }
    }
}

struct DaemonStatus: Decodable {
    var pid: Int
    var ready: Bool
    var ip: String
    var engine: String?
    var cpus: Int
    var memoryGiB: Int
    var balloonMiB: Int
    var guestMemTotalMiB: Int
    var guestMemAvailableMiB: Int
    var bootSeconds: Double
    var forwards: [String]
    var accel: [AccelService]?
    /// Translator per x86 architecture: "amd64"/"386" → "rosetta", "fex" or "qemu".
    var x86: [String: String]?
    /// x86 translators get x86's memory order from the CPU (mdock's guest kernel).
    var tso: Bool?
    var kernel: String?
    var kubernetes: KubernetesInfo?
    var idleStop: IdleStop?

    struct KubernetesInfo: Decodable {
        var state: String
        var version: String?
    }

    struct IdleStop: Decodable {
        var enabled: Bool
        var minutes: Int
    }

    var isGPU: Bool { engine?.contains("GPU") ?? false }
}

struct Container: Decodable, Identifiable, Hashable {
    struct Port: Decodable, Hashable {
        var IP: String?
        var PrivatePort: Int
        var PublicPort: Int?
        var `Type`: String
    }
    var Id: String
    var Names: [String]
    var Image: String
    var State: String
    var Status: String
    var Ports: [Port]
    var Created: Int

    var id: String { Id }
    var name: String { Names.first.map { String($0.dropFirst()) } ?? String(Id.prefix(12)) }
    var running: Bool { State == "running" }
    var publishedTCP: [Int] {
        Array(Set(Ports.compactMap { $0.Type == "tcp" ? $0.PublicPort : nil })).sorted()
    }
}

struct DockerImage: Decodable, Identifiable, Hashable {
    var Id: String
    var RepoTags: [String]?
    var Size: Int64
    var Created: Int

    var id: String { Id }
    var name: String { RepoTags?.first(where: { $0 != "<none>:<none>" }) ?? String(Id.dropFirst(7).prefix(12)) }
}

struct ContainerDetail: Decodable {
    struct HostConfigInfo: Decodable {
        var Devices: [Device]?
        var DeviceRequests: [DeviceRequest]?
        struct Device: Decodable { var PathOnHost: String? }
        struct DeviceRequest: Decodable { var Driver: String?; var DeviceIDs: [String]? }
    }
    var HostConfig: HostConfigInfo
    var Config: ConfigInfo
    struct ConfigInfo: Decodable { var Env: [String]? }

    /// Uses the mdock GPU (CDI device or raw /dev/dri passthrough).
    var usesGPU: Bool {
        let cdi = HostConfig.DeviceRequests?.contains { ($0.DeviceIDs ?? []).contains { $0.hasPrefix("mdock.dev/gpu") } } ?? false
        let dri = HostConfig.Devices?.contains { ($0.PathOnHost ?? "").hasPrefix("/dev/dri") } ?? false
        return cdi || dri
    }
}

struct AccelService: Decodable, Identifiable {
    var name: String
    var port: Int
    var built: Bool
    var running: Bool
    var id: String { name }
}
