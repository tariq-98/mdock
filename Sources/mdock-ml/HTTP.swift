import Foundation

/// A parsed HTTP/1.1 request. Bodies above `HTTPServer.spoolThreshold` are spooled to a temp file.
final class HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    fileprivate(set) var bodyData = Data()
    fileprivate(set) var bodyFile: URL?

    init(method: String, target: String, headers: [String: String]) {
        self.method = method
        self.headers = headers
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        path = String(parts.first ?? "/").removingPercentEncoding ?? String(parts.first ?? "/")
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1 ? String(kv[1]).replacingOccurrences(of: "+", with: " ") : ""
                query[key] = value.removingPercentEncoding ?? value
            }
        }
        self.query = query
    }

    deinit { if let bodyFile { try? FileManager.default.removeItem(at: bodyFile) } }

    var contentType: String { headers["content-type"] ?? "" }

    /// The whole body in memory (reads the spool file if there is one).
    func body() throws -> Data {
        if let bodyFile { return try Data(contentsOf: bodyFile, options: .mappedIfSafe) }
        return bodyData
    }

    /// The body as a file on disk, writing one if the body was kept in memory.
    func bodyAsFile() throws -> URL {
        if let bodyFile { return bodyFile }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mdock-ml-\(UUID().uuidString)")
        try bodyData.write(to: url)
        bodyFile = url
        return url
    }

    func json() throws -> [String: Any] {
        let data = try body()
        guard !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HTTPError(400, "request body must be a JSON object")
        }
        return object
    }
}

/// An error that maps to an HTTP status and an OpenAI-style error body.
struct HTTPError: Error {
    var status: Int
    var message: String
    var type: String
    var code: String?

    init(_ status: Int, _ message: String, type: String? = nil, code: String? = nil) {
        self.status = status
        self.message = message
        self.type = type ?? (status >= 500 ? "server_error" : "invalid_request_error")
        self.code = code
    }

    var body: [String: Any] {
        var error: [String: Any] = ["message": message, "type": type]
        error["code"] = code ?? NSNull()
        return ["error": error]
    }
}

struct WriteFailed: Error {}

/// Writes a response on a connection: either a whole body, or a chunked stream.
final class HTTPResponder {
    private let fd: Int32
    let isHead: Bool
    private(set) var started = false
    private var chunked = false
    var keepAlive: Bool

    init(fd: Int32, isHead: Bool, keepAlive: Bool) {
        self.fd = fd
        self.isHead = isHead
        self.keepAlive = keepAlive
    }

    func send(_ status: Int, _ body: Data, contentType: String, headers: [String: String] = [:]) {
        guard !started else { return }
        started = true
        var head = statusLine(status)
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var out = Data(head.utf8)
        if !isHead { out.append(body) }
        if (try? writeAll(out)) == nil { keepAlive = false }
    }

    func json(_ status: Int, _ object: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: JSON.sanitize(object), options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        send(status, data, contentType: "application/json")
    }

    func text(_ status: Int, _ string: String, contentType: String = "text/plain; charset=utf-8") {
        send(status, Data(string.utf8), contentType: contentType)
    }

    func error(_ error: HTTPError) { json(error.status, error.body) }

    /// Starts a chunked response (used for SSE).
    func begin(_ status: Int, contentType: String) throws {
        guard !started else { return }
        started = true
        chunked = true
        var head = statusLine(status)
        head += "Content-Type: \(contentType)\r\nTransfer-Encoding: chunked\r\nCache-Control: no-cache\r\n"
        head += "X-Accel-Buffering: no\r\nConnection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        try writeAll(Data(head.utf8))
    }

    func chunk(_ data: Data) throws {
        guard chunked, !data.isEmpty, !isHead else { return }
        var out = Data(String(data.count, radix: 16).utf8)
        out.append(contentsOf: [13, 10])
        out.append(data)
        out.append(contentsOf: [13, 10])
        try writeAll(out)
    }

    /// Sends one server-sent event (`data: <json>`).
    func event(_ object: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: JSON.sanitize(object), options: [.withoutEscapingSlashes])
        var out = Data("data: ".utf8)
        out.append(data)
        out.append(contentsOf: [10, 10])
        try chunk(out)
    }

    func end() {
        guard chunked else { return }
        chunked = false
        if (try? writeAll(Data("0\r\n\r\n".utf8))) == nil { keepAlive = false }
    }

    private static let reasons = [
        200: "OK", 201: "Created", 204: "No Content", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed",
        413: "Payload Too Large", 429: "Too Many Requests", 431: "Request Header Fields Too Large",
        500: "Internal Server Error", 501: "Not Implemented", 503: "Service Unavailable",
    ]

    private func statusLine(_ status: Int) -> String {
        "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
            + "Server: mdock-ml\r\nDate: \(HTTPServer.httpDate())\r\n"
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { throw WriteFailed() }
                offset += n
            }
        }
    }
}

/// A small HTTP/1.1 server: one thread per connection, keep-alive, chunked request bodies,
/// `Expect: 100-continue`, chunked/SSE responses.
final class HTTPServer {
    typealias Handler = (HTTPRequest, HTTPResponder) throws -> Void

    static let spoolThreshold = 8 << 20
    static let maxBody = 4 << 30
    private let handler: Handler

    init(handler: @escaping Handler) { self.handler = handler }

    func serve(listener fd: Int32) -> Never {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED || errno == EAGAIN { continue }
                Log.info("accept: \(String(cString: strerror(errno)))")
                usleep(100_000)
                continue
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 600, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let thread = Thread { [self] in
                connection(client)
                close(client)
            }
            thread.stackSize = 4 << 20
            thread.start()
        }
    }

    private func connection(_ fd: Int32) {
        let reader = Reader(fd: fd)
        while true {
            let request: HTTPRequest
            let keepAlive: Bool
            do {
                guard let head = try reader.head() else { return }
                let lines = head.components(separatedBy: "\r\n")
                let parts = lines[0].split(separator: " ")
                guard parts.count == 3 else { throw HTTPError(400, "bad request line") }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() where !line.isEmpty {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = line[..<colon].lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    headers[key] = headers[key].map { "\($0), \(value)" } ?? value
                }
                let version = String(parts[2])
                let connection = headers["connection"]?.lowercased() ?? ""
                keepAlive = version == "HTTP/1.1" ? !connection.contains("close") : connection.contains("keep-alive")
                request = HTTPRequest(method: String(parts[0]), target: String(parts[1]), headers: headers)
                if headers["expect"]?.lowercased() == "100-continue" {
                    reader.writeRaw("HTTP/1.1 100 Continue\r\n\r\n")
                }
                try readBody(request, reader)
            } catch let error as HTTPError {
                let responder = HTTPResponder(fd: fd, isHead: false, keepAlive: false)
                responder.error(error)
                return
            } catch {
                return
            }
            let responder = HTTPResponder(fd: fd, isHead: request.method == "HEAD", keepAlive: keepAlive)
            let start = Date()
            do {
                try handler(request, responder)
            } catch let error as HTTPError {
                if responder.started { responder.keepAlive = false } else { responder.error(error) }
            } catch is WriteFailed {
                responder.keepAlive = false
            } catch {
                if responder.started { responder.keepAlive = false }
                else { responder.error(HTTPError(500, "\(error)")) }
            }
            responder.end()
            if !responder.started { responder.error(HTTPError(500, "no response")) }
            Log.info("\(request.method) \(request.path) \(Int(Date().timeIntervalSince(start) * 1000))ms")
            if !responder.keepAlive { return }
        }
    }

    private func readBody(_ request: HTTPRequest, _ reader: Reader) throws {
        let sink = BodySink()
        if request.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            while true {
                guard let line = try reader.line() else { throw HTTPError(400, "truncated chunked body") }
                let sizeText = line.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                guard let size = Int(sizeText, radix: 16), size >= 0 else { throw HTTPError(400, "bad chunk size") }
                if size == 0 {
                    while let trailer = try reader.line(), !trailer.isEmpty {}
                    break
                }
                guard sink.count + size <= Self.maxBody else { throw HTTPError(413, "body too large") }
                try reader.read(size) { try sink.append($0) }
                _ = try reader.line()
            }
        } else if let lengthText = request.headers["content-length"] {
            guard let length = Int(lengthText), length >= 0 else { throw HTTPError(400, "bad content-length") }
            guard length <= Self.maxBody else { throw HTTPError(413, "body too large") }
            try reader.read(length) { try sink.append($0) }
        }
        try sink.finish()
        request.bodyData = sink.data
        request.bodyFile = sink.file
    }

    static func httpDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date())
    }
}

/// Collects a request body in memory, switching to a temp file past the spool threshold.
private final class BodySink {
    var data = Data()
    var file: URL?
    private var handle: FileHandle?
    private(set) var count = 0

    func append(_ bytes: UnsafeRawBufferPointer) throws {
        count += bytes.count
        if handle == nil && data.count + bytes.count > HTTPServer.spoolThreshold {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("mdock-ml-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            handle = try FileHandle(forWritingTo: url)
            file = url
            try handle!.write(contentsOf: data)
            data = Data()
        }
        if let handle { try handle.write(contentsOf: Data(bytes)) } else { data.append(contentsOf: bytes) }
    }

    func finish() throws { try handle?.close() }
}

/// Buffered reader over a socket.
private final class Reader {
    let fd: Int32
    private var buffer = [UInt8]()
    private var start = 0
    private var chunk = [UInt8](repeating: 0, count: 256 * 1024)

    init(fd: Int32) { self.fd = fd }

    private func fill() throws -> Bool {
        if start > 0 && start == buffer.count { buffer.removeAll(keepingCapacity: true); start = 0 }
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            buffer.append(contentsOf: chunk[0..<n])
            return true
        }
    }

    /// Reads the request head (up to the blank line). Nil on a clean close before any byte.
    func head() throws -> String? {
        var scanned = 0 // bytes after `start` already searched (minus 3 for a split terminator)
        while true {
            var i = start + max(0, scanned - 3)
            while i + 3 < buffer.count {
                if buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10 {
                    var head = String(decoding: buffer[start..<i], as: UTF8.self)
                    start = i + 4
                    // Tolerate stray CRLFs between pipelined requests.
                    while head.hasPrefix("\r\n") { head.removeFirst() }
                    return head
                }
                i += 1
            }
            scanned = buffer.count - start
            if scanned > 64 * 1024 { throw HTTPError(431, "request header too large") }
            if !(try fill()) {
                if buffer.count == start { return nil }
                throw HTTPError(400, "truncated request")
            }
        }
    }

    func line() throws -> String? {
        while true {
            if let nl = buffer[start...].firstIndex(of: 10) {
                var end = nl
                if end > start && buffer[end - 1] == 13 { end -= 1 }
                let line = String(decoding: buffer[start..<end], as: UTF8.self)
                start = nl + 1
                return line
            }
            if buffer.count - start > 64 * 1024 { throw HTTPError(400, "line too long") }
            if !(try fill()) { return nil }
        }
    }

    func read(_ count: Int, into body: (UnsafeRawBufferPointer) throws -> Void) throws {
        var remaining = count
        while remaining > 0 {
            if start == buffer.count, !(try fill()) { throw HTTPError(400, "truncated body") }
            let n = min(remaining, buffer.count - start)
            try buffer.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0[start..<start + n])) }
            start += n
            remaining -= n
        }
    }

    func writeRaw(_ string: String) {
        let bytes = Array(string.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

enum Listener {
    static func unix(_ path: String) throws -> Int32 {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HTTPError(500, "socket: \(errno)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw HTTPError(500, "socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        // Create the socket owner-only from the start.
        let oldMask = umask(0o177)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard ok == 0, listen(fd, 256) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw HTTPError(500, "listen \(path): \(message)")
        }
        chmod(path, 0o600)
        return fd
    }

    /// Test-only TCP listener on one explicit IPv4 address; wildcard addresses are refused.
    static func tcp(_ spec: String) throws -> Int32 {
        let parts = spec.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { throw HTTPError(400, "--tcp wants <ipv4>:<port>") }
        let host = String(parts[0])
        var addr = sockaddr_in()
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { throw HTTPError(400, "--tcp wants an IPv4 address") }
        guard addr.sin_addr.s_addr != 0 else { throw HTTPError(400, "refusing to listen on 0.0.0.0") }
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0, listen(fd, 256) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw HTTPError(500, "listen \(spec): \(message)")
        }
        return fd
    }
}
