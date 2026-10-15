import Foundation

/// A bounded FIFO of byte chunks between a reader and a writer thread (see Sockets.splice). Chunk
/// buffers are recycled: allocating a fresh 256 KiB buffer per read costs page faults at GB/s. One
/// side at a time holds the write turn: the writer while it writes a popped chunk, the reader while
/// it writes directly (allowed only when nothing is queued), which keeps the bytes in order.
final class ByteQueue {
    typealias Chunk = (buffer: UnsafeMutableRawPointer, start: Int, count: Int)
    let chunkSize: Int
    private let condition = NSCondition()
    private var chunks: [Chunk] = []
    private var head = 0
    private var bytes = 0
    private var finished = false
    private var aborted = false
    private var writing = false
    private var spare: [UnsafeMutableRawPointer] = []
    private var owned: [UnsafeMutableRawPointer] = []
    private let limit: Int

    init(limit: Int, chunkSize: Int = 256 * 1024) {
        self.limit = limit
        self.chunkSize = chunkSize
    }

    deinit { owned.forEach { $0.deallocate() } }

    /// A chunkSize buffer to read into; hand it back with push or recycle.
    func buffer() -> UnsafeMutableRawPointer {
        condition.lock()
        defer { condition.unlock() }
        if let buffer = spare.popLast() { return buffer }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        owned.append(buffer)
        return buffer
    }

    func recycle(_ buffer: UnsafeMutableRawPointer) {
        condition.lock()
        spare.append(buffer)
        condition.unlock()
    }

    /// Reader: takes the write turn if nothing is queued or being written. Release with endDirect.
    func beginDirect() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !aborted, head == chunks.count, !writing else { return false }
        writing = true
        return true
    }

    func endDirect() {
        condition.lock()
        writing = false
        condition.signal()
        condition.unlock()
    }

    /// Queues bytes of a buffer from buffer(). False once more than `limit` bytes are queued or
    /// the queue was aborted; the caller then recycles the buffer.
    func push(_ buffer: UnsafeMutableRawPointer, start: Int = 0, _ count: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !aborted else { return false }
        chunks.append((buffer, start, count))
        bytes += count
        if bytes > limit { aborted = true }
        condition.signal()
        return !aborted
    }

    /// Copies arbitrary data in, a chunk at a time.
    func push(_ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let n = min(chunkSize, data.count - offset)
            let buffer = self.buffer()
            data.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress! + offset, byteCount: n) }
            guard push(buffer, n) else {
                recycle(buffer)
                return false
            }
            offset += n
        }
        return true
    }

    /// Writer: the next chunk, with the write turn; nil at the end of the stream or after an abort.
    /// Call done() once it is written, and recycle its buffer.
    func pop() -> Chunk? {
        condition.lock()
        defer { condition.unlock() }
        while (head == chunks.count || writing) && !finished && !aborted { condition.wait() }
        while writing && !aborted { condition.wait() }
        guard !aborted, head < chunks.count else { return nil }
        let chunk = chunks[head]
        head += 1
        bytes -= chunk.count
        writing = true
        if head > 64 && head * 2 > chunks.count {
            chunks.removeFirst(head)
            head = 0
        }
        return chunk
    }

    func done() {
        condition.lock()
        writing = false
        condition.unlock()
    }

    func finish() {
        condition.lock()
        finished = true
        condition.signal()
        condition.unlock()
    }

    func abort() {
        condition.lock()
        aborted = true
        condition.signal()
        condition.unlock()
    }

    var isAborted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return aborted
    }
}

final class Cancel {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

enum Sockets {
    static func unixListen(_ path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CommandError(description: "socket: \(errno)") }
        var addr = unixAddress(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0, listen(fd, 128) == 0 else {
            close(fd)
            throw CommandError(description: "listen \(path): \(String(cString: strerror(errno)))")
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

    /// Listens on TCP. A nil host means all interfaces, dual-stack.
    static func tcpListen(host: String?, port: UInt16) throws -> Int32 {
        var one: Int32 = 1
        if let host {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            inet_pton(AF_INET, host, &addr.sin_addr)
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            return try finishListen(fd, ok, "\(host):\(port)")
        }
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        var zero: Int32 = 0
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        return try finishListen(fd, ok, "*:\(port)")
    }

    private static func finishListen(_ fd: Int32, _ bindResult: Int32, _ label: String) throws -> Int32 {
        guard bindResult == 0, listen(fd, 512) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw CommandError(description: "listen \(label): \(message)")
        }
        return fd
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
        return fd
    }

    static func tcp6Connect(host: String, port: UInt16) -> Int32? {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        inet_pton(AF_INET6, host, &addr.sin6_addr)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        if ok != 0 { close(fd); return nil }
        return fd
    }

    /// Whether a socket address is loopback (127/8, ::1, or ::ffff:127/8).
    static func isLoopback(_ addr: UnsafePointer<sockaddr>) -> Bool {
        switch Int32(addr.pointee.sa_family) {
        case AF_INET:
            return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) >> 24 == 127 }
        case AF_INET6:
            return addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                let b = withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) }
                let v6Loopback = b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1
                let mapped127 = b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xff && b[11] == 0xff && b[12] == 127
                return v6Loopback || mapped127
            }
        default:
            return false
        }
    }

    /// Whether a connected socket's peer is on this Mac.
    static func peerIsLoopback(_ fd: Int32) -> Bool {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        return withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) == 0 && isLoopback($0) }
        }
    }

    /// A UDP socket bound to host:port (all interfaces, IPv4 and IPv6, when host is nil).
    static func udpBind(host: String?, port: UInt16) throws -> Int32 {
        var one: Int32 = 1, zero: Int32 = 0
        let fd: Int32
        let ok: Int32
        if let host {
            fd = socket(AF_INET, SOCK_DGRAM, 0)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            inet_pton(AF_INET, host, &addr.sin_addr)
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        } else {
            fd = socket(AF_INET6, SOCK_DGRAM, 0)
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = in6addr_any
            ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        guard fd >= 0, ok == 0 else {
            let message = String(cString: strerror(errno))
            if fd >= 0 { close(fd) }
            throw CommandError(description: "udp bind \(host ?? "*"):\(port): \(message)")
        }
        return fd
    }

    /// A UDP socket connected to host:port (IPv4).
    static func udpConnect(host: String, port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if ok != 0 { close(fd); return nil }
        return fd
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = write(fd, bytes + offset, count - offset)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    /// Reads exactly `count` bytes into the start of `buffer`.
    static func readFull(_ fd: Int32, _ buffer: inout [UInt8], _ count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, count - offset) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    /// Accepts connections until `cancel` is set, then closes the listener.
    static func acceptLoop(_ fd: Int32, cancel: Cancel = Cancel(), handler: @escaping (Int32) -> Void) {
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
                var one: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                handler(client)
            }
        }
    }

    private static let devNull = open("/dev/null", O_RDWR)

    /// shutdown(SHUT_RDWR), one direction at a time. On a unix socket whose peer has already shut its
    /// write side, macOS refuses SHUT_RDWR (and SHUT_RD) with ENOTCONN and shuts nothing, so the peer
    /// never sees EOF; SHUT_WR on its own still works.
    static func shutdownBoth(_ fd: Int32) {
        shutdown(fd, SHUT_WR)
        shutdown(fd, SHUT_RD)
    }

    /// Waits until a non-blocking fd is ready; false after `timeout` ms.
    @discardableResult
    static func wait(_ fd: Int32, _ events: Int32, timeout: Int32 = -1) -> Bool {
        var p = pollfd(fd: fd, events: Int16(events), revents: 0)
        while true {
            let r = poll(&p, 1, timeout)
            if r < 0 && errno == EINTR { continue }
            return r > 0
        }
    }

    /// writeAll for a non-blocking fd: waits for room, but by default gives up after 60 s without
    /// progress (a peer that stopped reading for good).
    static func writeWaiting(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int, timeout: Int32 = 60_000) -> Bool {
        var offset = 0
        while offset < count {
            let n = write(fd, bytes + offset, count - offset)
            if n > 0 {
                offset += n
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                guard wait(fd, POLLOUT, timeout: timeout) else { return false }
            } else {
                return false
            }
        }
        return true
    }

    /// Closes the socket behind `fd` right away while keeping the descriptor number reserved (it now
    /// refers to /dev/null) until the final close(), so threads still holding it can't hit a reused
    /// descriptor. A peer writing into that socket gets an error instead of blocking.
    static func release(_ fd: Int32) {
        dup2(devNull, fd)
    }

    /// Copies bytes both ways, propagating half-close, then closes both descriptors.
    ///
    /// `vsock` is whichever of the two is a stream from the guest's vsock (or the GPU engine's
    /// equivalent), if either. Virtualization.framework writes guest data into the Mac's sockets from
    /// one serial queue per VM, so a single host socket left unread blocks every vsock connection
    /// (docker.sock, ports, the guest's reports): what comes out of `vsock` is read promptly however
    /// slow its destination is, with up to `limit` bytes queued between a reader and a writer thread,
    /// and a direction that falls `limit` behind tears its connection down. Every other direction
    /// reads only as fast as its destination takes the bytes, so TCP's flow control slows a fast
    /// sender down instead (an upload from the Mac outruns vsock within milliseconds).
    static func splice(_ a: Int32, _ b: Int32, vsock: Int32?, limit: Int = 64 << 20, onClose: (() -> Void)? = nil) {
        // Non-blocking, so the reader's direct write can never block (macOS ignores MSG_DONTWAIT on
        // these sockets); readers and the writer wait in poll() instead.
        for fd in [a, b] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        let group = DispatchGroup()
        for (src, dst) in [(a, b), (b, a)] {
            if src != vsock {
                group.enter()
                Thread.detachNewThread {
                    defer { group.leave() }
                    copy(src, dst)
                }
                continue
            }
            let queue = ByteQueue(limit: limit)
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                func fail(_ buffer: UnsafeMutableRawPointer) {
                    queue.recycle(buffer)
                    queue.abort()
                    release(src)
                    shutdownBoth(dst)
                }
                while true {
                    let buffer = queue.buffer()
                    let n = read(src, buffer, queue.chunkSize)
                    if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                        queue.recycle(buffer)
                        if errno != EINTR { wait(src, POLLIN) }
                        continue
                    }
                    if n <= 0 {
                        queue.recycle(buffer)
                        queue.finish()
                        if queue.isAborted { release(src) }  // the writer gave up: stop taking data now
                        return
                    }
                    // Fast path, nothing queued: write without blocking; queue only what doesn't fit.
                    var sent = 0
                    if queue.beginDirect() {
                        repeat {
                            let w = write(dst, buffer + sent, n - sent)
                            if w > 0 { sent += w } else if w < 0 && errno == EINTR { continue } else { break }
                        } while sent < n
                        if sent < n && errno != EAGAIN && errno != EWOULDBLOCK {  // the destination is gone
                            queue.endDirect()
                            return fail(buffer)
                        }
                        let queued = sent == n || queue.push(buffer, start: sent, n - sent)
                        queue.endDirect()
                        if sent == n { queue.recycle(buffer) }
                        guard queued else { return fail(buffer) }
                        continue
                    }
                    guard queue.push(buffer, n) else { return fail(buffer) }  // over the limit, or the writer failed
                }
            }
            group.enter()
            Thread.detachNewThread {
                defer { group.leave() }
                while let chunk = queue.pop() {
                    let written = writeWaiting(dst, chunk.buffer + chunk.start, chunk.count)
                    queue.recycle(chunk.buffer)
                    queue.done()
                    guard written else {
                        queue.abort()
                        shutdownBoth(src)  // wakes the reader
                        return
                    }
                }
                shutdown(dst, SHUT_WR)
            }
        }
        group.notify(queue: .global()) {
            close(a)
            close(b)
            onClose?()
        }
    }

    /// One direction of a splice with flow control: each read is written out before the next.
    private static func copy(_ src: Int32, _ dst: Int32) {
        let size = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let n = read(src, buffer, size)
            if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                if errno != EINTR { wait(src, POLLIN) }
                continue
            }
            if n <= 0 { break }
            // No time limit: a client that stops reading for a while (a paused video) keeps its
            // connection, and only this connection waits for it.
            guard writeWaiting(dst, buffer, n, timeout: -1) else {
                shutdownBoth(src)  // the destination is gone: end the connection
                return
            }
        }
        shutdown(dst, SHUT_WR)
    }

    static func readLine(_ fd: Int32, limit: Int = 4096) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < limit {
            let n = read(fd, &byte, 1)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            if byte == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    static func writeAll(_ fd: Int32, _ string: String) {
        var data = Array(string.utf8)[...]
        while !data.isEmpty {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            data = data.dropFirst(n)
        }
    }
}

/// posix_spawn attributes for child processes: default signal handlers and an empty mask. The daemon
/// ignores SIGTERM/SIGINT itself (it handles them via dispatch sources), and ignored dispositions are
/// inherited across exec, which would make services impossible to stop.
func withChildSpawnAttributes<T>(_ body: (UnsafePointer<posix_spawnattr_t?>) -> T) -> T {
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    var all = sigset_t(), none = sigset_t()
    sigfillset(&all)
    sigemptyset(&none)
    posix_spawnattr_setsigdefault(&attr, &all)
    posix_spawnattr_setsigmask(&attr, &none)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    return withUnsafePointer(to: &attr) { body($0) }
}
