import Foundation

struct LLMError: Error, CustomStringConvertible {
    var description: String
    var status: Int = 500
}

final class Cancel {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

enum Sockets {
    static func unixListen(_ path: String) throws -> Int32 {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw LLMError(description: "socket path too long (max 103 bytes): \(path)")
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LLMError(description: "socket: \(errno)") }
        var addr = unixAddress(path)
        // Create the socket with mode 0600 from the start; there is no window where it is wider.
        let previous = umask(0o177)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previous)
        guard ok == 0, listen(fd, 128) == 0 else {
            close(fd)
            throw LLMError(description: "listen \(path): \(String(cString: strerror(errno)))")
        }
        chmod(path, 0o600)
        return fd
    }

    static func unixConnect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = unixAddress(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if ok != 0 { close(fd); return nil }
        noSigpipe(fd)
        return fd
    }

    private static func unixAddress(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    /// Listens on one IPv4 address (test listeners only; never 0.0.0.0 by default).
    static func tcpListen(host: String, port: UInt16) throws -> Int32 {
        var one: Int32 = 1
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            close(fd)
            throw LLMError(description: "invalid IPv4 address \(host)")
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0, listen(fd, 128) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw LLMError(description: "listen \(host):\(port): \(message)")
        }
        return fd
    }

    /// Picks a free loopback port by binding port 0. The port is released before the caller uses it.
    static func freeLoopbackPort() throws -> UInt16 {
        let fd = try tcpListen(host: "127.0.0.1", port: 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    static func tcpConnect(host: String, port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if ok != 0 { close(fd); return nil }
        noSigpipe(fd)
        return fd
    }

    static func noSigpipe(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Accepts connections until `cancel` is set; each client is handled on its own thread.
    static func acceptLoop(_ fd: Int32, cancel: Cancel, handler: @escaping (Int32) -> Void) {
        Thread.detachNewThread {
            defer { close(fd) }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            while !cancel.isSet {
                let ready = poll(&pfd, 1, 250)
                if ready <= 0 { continue }
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR || errno == ECONNABORTED || errno == EAGAIN { continue }
                    return
                }
                noSigpipe(client)
                Thread.detachNewThread { handler(client) }
            }
        }
    }

    /// Copies bytes both ways, propagating half-close, then closes both descriptors.
    /// `done` runs after both directions finish.
    static func splice(_ a: Int32, _ b: Int32, done: (() -> Void)? = nil) {
        let group = DispatchGroup()
        for (src, dst) in [(a, b), (b, a)] {
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                let size = 256 * 1024
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
                defer { buffer.deallocate() }
                copy: while true {
                    let n = read(src, buffer, size)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    if !writeAll(dst, UnsafeRawPointer(buffer), n) {
                        shutdown(src, SHUT_RDWR)
                        break copy
                    }
                }
                shutdown(dst, SHUT_WR)
            }
        }
        group.notify(queue: .global()) {
            close(a)
            close(b)
            done?()
        }
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let w = write(fd, pointer + offset, count - offset)
            if w < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += w
        }
        return true
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            return writeAll(fd, base, raw.count)
        }
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ string: String) -> Bool {
        writeAll(fd, Data(string.utf8))
    }
}

/// Buffered reader over a socket: lines, exact lengths, and HTTP chunked bodies.
final class Reader {
    let fd: Int32
    private var buffer = [UInt8]()
    private var start = 0
    private var eof = false

    init(_ fd: Int32) { self.fd = fd }

    private var available: Int { buffer.count - start }

    /// Reads more bytes from the socket. Returns false at EOF or on error.
    private func fill() -> Bool {
        if eof { return false }
        if start > 0 && start == buffer.count { buffer.removeAll(keepingCapacity: true); start = 0 }
        if start > 64 * 1024 { buffer.removeSubrange(0..<start); start = 0 }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { eof = true; return false }
            buffer.append(contentsOf: chunk[0..<n])
            return true
        }
    }

    /// One line without its CRLF/LF, or nil at EOF.
    func readLine(limit: Int = 64 * 1024) -> String? {
        var scanned = 0
        while true {
            if let index = buffer[(start + scanned)...].firstIndex(of: UInt8(ascii: "\n")) {
                var end = index
                if end > start && buffer[end - 1] == UInt8(ascii: "\r") { end -= 1 }
                let line = String(decoding: buffer[start..<end], as: UTF8.self)
                start = index + 1
                return line
            }
            scanned = available
            if scanned > limit { return nil }
            if !fill() {
                if available == 0 { return nil }
                let line = String(decoding: buffer[start...], as: UTF8.self)
                start = buffer.count
                return line
            }
        }
    }

    /// Up to `max` bytes that are already buffered, or one read's worth. Empty at EOF.
    func readSome(max: Int = 64 * 1024) -> Data {
        if available == 0 && !fill() { return Data() }
        let n = min(max, available)
        let data = Data(buffer[start..<(start + n)])
        start += n
        return data
    }

    func readExact(_ count: Int) -> Data? {
        var out = Data()
        out.reserveCapacity(count)
        while out.count < count {
            let piece = readSome(max: count - out.count)
            if piece.isEmpty { return nil }
            out.append(piece)
        }
        return out
    }

    /// Reads until EOF (bounded).
    func readToEnd(limit: Int) -> Data? {
        var out = Data()
        while true {
            let piece = readSome()
            if piece.isEmpty { return out }
            out.append(piece)
            if out.count > limit { return nil }
        }
    }
}

struct HTTPHeaders {
    var fields: [(String, String)] = []

    subscript(_ name: String) -> String? {
        fields.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    static func read(_ reader: Reader) -> HTTPHeaders? {
        var headers = HTTPHeaders()
        while let line = reader.readLine() {
            if line.isEmpty { return headers }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.fields.append((name, value))
            if headers.fields.count > 200 { return nil }
        }
        return nil
    }

    var isChunked: Bool { self["Transfer-Encoding"]?.lowercased().contains("chunked") ?? false }
    var contentLength: Int? { self["Content-Length"].flatMap { Int($0) } }
}

/// Body framing shared by requests and responses.
enum HTTPBody {
    /// Calls `sink` with each piece of the body as it arrives. Returns false on a framing error
    /// or when `sink` returns false.
    static func stream(_ reader: Reader, headers: HTTPHeaders, untilEOF: Bool, sink: (Data) -> Bool) -> Bool {
        if headers.isChunked {
            while let sizeLine = reader.readLine() {
                let hex = sizeLine.split(separator: ";").first.map(String.init) ?? ""
                guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else { return false }
                if size == 0 {
                    while let trailer = reader.readLine(), !trailer.isEmpty {}
                    return true
                }
                var remaining = size
                while remaining > 0 {
                    let piece = reader.readSome(max: remaining)
                    if piece.isEmpty { return false }
                    remaining -= piece.count
                    if !sink(piece) { return false }
                }
                _ = reader.readLine()
            }
            return false
        }
        if let length = headers.contentLength {
            var remaining = length
            while remaining > 0 {
                let piece = reader.readSome(max: remaining)
                if piece.isEmpty { return false }
                remaining -= piece.count
                if !sink(piece) { return false }
            }
            return true
        }
        if untilEOF {
            while true {
                let piece = reader.readSome()
                if piece.isEmpty { return true }
                if !sink(piece) { return false }
            }
        }
        return true
    }

    static func read(_ reader: Reader, headers: HTTPHeaders, untilEOF: Bool, limit: Int) -> Data? {
        var out = Data()
        let ok = stream(reader, headers: headers, untilEOF: untilEOF) { piece in
            out.append(piece)
            return out.count <= limit
        }
        return ok ? out : nil
    }
}

struct HTTPRequest {
    var method: String
    var target: String
    var headers: HTTPHeaders
    var body: Data

    var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }

    static let maxBody = 256 << 20

    static func read(_ reader: Reader) throws -> HTTPRequest? {
        guard let line = reader.readLine(limit: 16 * 1024), !line.isEmpty else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            throw LLMError(description: "malformed request line", status: 400)
        }
        guard let headers = HTTPHeaders.read(reader) else {
            throw LLMError(description: "malformed headers", status: 400)
        }
        if headers["Expect"]?.lowercased() == "100-continue" {
            Sockets.writeAll(reader.fd, "HTTP/1.1 100 Continue\r\n\r\n")
        }
        if let length = headers.contentLength, length > maxBody {
            throw LLMError(description: "request body too large", status: 413)
        }
        guard let body = HTTPBody.read(reader, headers: headers, untilEOF: false, limit: maxBody) else {
            throw LLMError(description: "malformed or oversized body", status: 400)
        }
        return HTTPRequest(method: String(parts[0]), target: String(parts[1]), headers: headers, body: body)
    }

    var json: [String: Any]? {
        guard !body.isEmpty else { return [:] }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

enum HTTPResponse {
    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 507: return "Insufficient Storage"
        default: return "Status"
        }
    }

    /// Writes a complete response; every response closes the connection.
    static func send(_ fd: Int32, status: Int = 200, contentType: String = "application/json", body: Data) {
        let head = "HTTP/1.1 \(status) \(reason(status))\r\nContent-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        Sockets.writeAll(fd, head)
        Sockets.writeAll(fd, body)
    }

    static func json(_ fd: Int32, status: Int = 200, _ object: Any) {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        send(fd, status: status, body: body)
    }

    /// OpenAI-style error envelope.
    static func error(_ fd: Int32, status: Int, _ message: String) {
        let type = status >= 500 ? "server_error" : "invalid_request_error"
        json(fd, status: status, ["error": ["message": message, "type": type, "code": status]])
    }

    /// Starts a chunked response; use `chunk` for each piece and `end` to finish.
    static func beginChunked(_ fd: Int32, status: Int = 200, contentType: String) -> Bool {
        Sockets.writeAll(fd, "HTTP/1.1 \(status) \(reason(status))\r\nContent-Type: \(contentType)\r\n"
            + "Transfer-Encoding: chunked\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n")
    }

    @discardableResult
    static func chunk(_ fd: Int32, _ data: Data) -> Bool {
        if data.isEmpty { return true }
        var framed = Data(String(data.count, radix: 16).utf8)
        framed.append(contentsOf: [13, 10])
        framed.append(data)
        framed.append(contentsOf: [13, 10])
        return Sockets.writeAll(fd, framed)
    }

    static func endChunked(_ fd: Int32) {
        Sockets.writeAll(fd, "0\r\n\r\n")
    }
}

func jsonData(_ object: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) mdock-llm: \(message)\n".utf8))
}
