import CoreVideo
import Foundation

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("\(stamp) \(message)\n".data(using: .utf8)!)
}

/// Accepts guest driver connections on a unix socket (or, for testing, one TCP address) and serves
/// each on its own thread.
final class Server {
    private let fd: Int32
    /// Directory for per-connection frame files, shared with containers (see PROTOCOL.md).
    var framesDir: String?

    init(unixPath: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        unlink(unixPath)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(unixPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        // Create the socket with 0600 directly: no window in which others could connect.
        let old = umask(0o177)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard rc == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        chmod(unixPath, 0o600)
        guard listen(fd, 64) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        log("listening on \(unixPath)")
    }

    /// Test-only TCP listener. Wildcard addresses are refused so the service never becomes
    /// reachable from the network; bind it to the vmnet bridge (192.168.64.1) or loopback.
    init(tcp spec: String) throws {
        let parts = spec.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { throw WireError(.invalidParameter, "--tcp wants ip:port") }
        let ip = String(parts[0])
        guard ip != "0.0.0.0", ip != "*", !ip.isEmpty else { throw WireError(.invalidParameter, "refusing to bind a wildcard address") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { throw WireError(.invalidParameter, "bad IPv4 address \(ip)") }
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard listen(fd, 64) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        log("listening on tcp \(spec) (test mode)")
    }

    func run() -> Never {
        var next = 1
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                log("accept: \(String(cString: strerror(errno)))")
                sleep(1)
                continue
            }
            var size: Int32 = 8 << 20
            setsockopt(client, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            var one: Int32 = 1
            setsockopt(client, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            // Replies never block for long: a client that stops reading is dropped (see writeAll).
            var tv = timeval(tv_sec: Connection.ioTimeout, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let conn = Connection(fd: client, id: next, framesDir: framesDir)
            next += 1
            let thread = Thread { conn.run() }
            thread.stackSize = 1 << 20
            thread.start()
        }
    }
}

/// One driver instance (one VADisplay). Owns its surfaces and codec sessions; everything is freed
/// when the guest process closes the socket.
final class Connection {
    private let fd: Int32
    private let id: Int
    private var surfaces: [UInt32: Surface] = [:]
    private var decoders: [UInt32: Decoder] = [:]
    private var encoders: [UInt32: Encoder] = [:]
    private var processor: Processor?
    /// Tag of the request being handled; replies echo it so async replies can be matched.
    private var currentTag: UInt16 = 0
    /// Replies come from the request thread and from VideoToolbox callbacks.
    private let writeLock = NSLock()
    private var closed = false
    /// Seconds a client may stall mid-message (or leave replies unread) before it is dropped.
    static let ioTimeout = 10
    private var payload = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16)
    private var capacity = 1 << 20
    private var frames = 0
    private let framesDir: String?
    private var frameFD: Int32 = -1
    private var framePath: String?

    init(fd: Int32, id: Int, framesDir: String?) {
        self.fd = fd
        self.id = id
        self.framesDir = framesDir
    }

    /// Creates this connection's frame file: a file in a directory the container also mounts,
    /// read and written by the driver with O_DIRECT, so pixels bypass the vsock relay.
    private func openFrameFile() -> String? {
        if frameFD >= 0 { return framePath.map { ($0 as NSString).lastPathComponent } }
        guard let dir = framesDir else { return nil }
        var rnd: UInt64 = 0
        arc4random_buf(&rnd, 8)
        let name = String(format: "vt-%d-%d-%016llx.frame", getpid(), id, rnd)
        let path = (dir as NSString).appendingPathComponent(name)
        let f = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard f >= 0 else {
            log("conn \(id): cannot create \(path): \(String(cString: strerror(errno)))")
            return nil
        }
        fchmod(f, 0o666)  // the container user is not the Mac user; the name is unguessable
        // Sized up front (sparse): the guest caches the file size, and O_DIRECT reads stop there.
        ftruncate(f, off_t(Wire.frameFileSize))
        frameFD = f
        framePath = path
        return name
    }

    private func reserve(_ n: Int) throws {
        if n > capacity {
            payload.deallocate()
            capacity = n
            payload = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        }
    }

    /// Writes the rows at offset 0, split over a few threads (the guest reads the file the same
    /// way; both sides go faster with several requests in flight).
    private func writeRows(_ file: Int32, _ parts: [iovec]) -> Bool {
        let total = parts.reduce(0) { $0 + $1.iov_len }
        let lanes = total >= 4 << 20 ? 4 : 1
        // Split at row boundaries into lanes of roughly equal bytes.
        var groups: [(offset: Int, rows: ArraySlice<iovec>)] = []
        var start = 0, offset = 0, acc = 0, groupOffset = 0
        for (i, v) in parts.enumerated() {
            acc += v.iov_len
            offset += v.iov_len
            if acc >= total / lanes, groups.count < lanes - 1 {
                groups.append((groupOffset, parts[start...i]))
                start = i + 1
                groupOffset = offset
                acc = 0
            }
        }
        if start < parts.count { groups.append((groupOffset, parts[start...])) }
        var ok = [Bool](repeating: true, count: groups.count)
        ok.withUnsafeMutableBufferPointer { result in
            DispatchQueue.concurrentPerform(iterations: groups.count) { g in
                result[g] = Connection.pwriteAll(file, Array(groups[g].rows), at: off_t(groups[g].offset))
            }
        }
        return !ok.contains(false)
    }

    private static func pwriteAll(_ file: Int32, _ parts: [iovec], at base: off_t) -> Bool {
        var offset = base
        var start = 0
        var iov = parts
        while start < iov.count {
            let n = min(iov.count - start, Int(IOV_MAX))
            let w = iov.withUnsafeMutableBufferPointer { pwritev(file, $0.baseAddress! + start, Int32(n), offset) }
            if w < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += off_t(w)
            var left = w
            while left > 0, start < iov.count {
                if left >= iov[start].iov_len {
                    left -= iov[start].iov_len
                    start += 1
                } else {
                    iov[start].iov_base += left
                    iov[start].iov_len -= left
                    left = 0
                }
            }
        }
        return true
    }

    func run() {
        log("conn \(id): open")
        var header = [UInt8](repeating: 0, count: Wire.headerSize)
        while true {
            guard header.withUnsafeMutableBytes({ readFully($0.baseAddress!, Wire.headerSize) }) else { break }
            let (magic, op, tag, length) = header.withUnsafeBytes { raw in
                (UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)),
                 UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt16.self)),
                 UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 6, as: UInt16.self)),
                 Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self))))
            }
            guard magic == Wire.magic, length <= 256 << 20 else {
                log("conn \(id): bad header, closing")
                break
            }
            if length > capacity {
                payload.deallocate()
                capacity = max(length, capacity * 2)
                payload = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
            }
            guard readFully(payload, length, timeout: true) else { break }
            currentTag = tag
            let ok = autoreleasepool {
                handle(op: op, UnsafeRawBufferPointer(start: payload, count: length))
            }
            guard ok else { break }
        }
        markClosed()
        encoders.removeAll()  // completes in-flight frames; their callbacks write nothing now
        for d in decoders.values { d.waitForFrames() }
        surfaces.removeAll()
        decoders.removeAll()
        processor = nil
        payload.deallocate()
        if frameFD >= 0 {
            close(frameFD)
            if let framePath { unlink(framePath) }
        }
        close(fd)
        log("conn \(id): closed after \(frames) frames")
    }

    /// Handles one request; returns false when the reply could not be written.
    private func handle(op raw: UInt16, _ body: UnsafeRawBufferPointer) -> Bool {
        var reply = Writer()
        var status = Wire.Status.ok
        do {
            guard let op = Wire.Op(rawValue: raw) else { throw WireError(.invalidParameter, "unknown op \(raw)") }
            var r = Reader(body)
            switch op {
            case .hello:
                let version = try r.u32()
                let flags = r.remaining >= 4 ? try r.u32() : 0
                if version != Wire.version { log("conn \(id): driver protocol \(version), host \(Wire.version)") }
                reply.u32(Wire.version)
                reply.u32(Capabilities.current.rawValue)
                reply.u32(8192)
                reply.u32(8192)
                if flags & Wire.helloWantsFrameFile != 0, let name = openFrameFile() {
                    let bytes = Array(name.utf8)
                    reply.u32(UInt32(bytes.count))
                    bytes.withUnsafeBytes { reply.append($0) }
                } else {
                    reply.u32(0)
                }

            case .surfaceCreate:
                let sid = try r.u32()
                let w = Int(try r.u32()), h = Int(try r.u32())
                let fourcc = try r.u32()
                surfaces[sid] = Surface(width: w, height: h, fourcc: fourcc)

            case .surfaceDestroy:
                surfaces[try r.u32()] = nil

            case .surfacePut:
                let s = try surface(try r.u32())
                let flags = try r.u32()
                if flags & Wire.viaFrameFile != 0 {
                    guard frameFD >= 0 else { throw WireError(.invalidParameter, "no frame file") }
                    let need = s.packedSize
                    try reserve(need)
                    guard pread(frameFD, payload, need, 0) == need else { throw WireError(.operationFailed, "frame file read") }
                    try s.put(UnsafeRawBufferPointer(start: payload, count: need))
                } else {
                    try s.put(r.rest())
                }

            case .surfaceGet:
                let s = try surface(try r.u32())
                let flags = r.remaining >= 4 ? try r.u32() : 0
                guard s.buffer != nil else {
                    reply.u32(0)
                    reply.u32(0)
                    break
                }
                if flags & Wire.viaFrameFile != 0, frameFD >= 0 {
                    guard s.withPackedRows({ writeRows(frameFD, $0) }) else {
                        throw WireError(.operationFailed, "frame file write")
                    }
                    reply.u32(1)
                    reply.u32(Wire.viaFrameFile)
                    break
                }
                return s.withPackedRows { rows in
                    var head: (UInt32, UInt32) = (UInt32(1).littleEndian, 0)
                    return withUnsafeMutableBytes(of: &head) { v in
                        sendReply(op: raw, status: .ok, parts: [iovec(iov_base: v.baseAddress, iov_len: 8)] + rows,
                                  length: 8 + s.packedSize)
                    }
                }

            case .surfaceCopy:
                let src = try surface(try r.u32())
                try surface(try r.u32()).buffer = src.buffer

            case .process:
                let src = try surface(try r.u32()), dst = try surface(try r.u32())
                var v = [Int]()
                for _ in 0..<8 { v.append(Int(try r.i32())) }
                guard let input = src.buffer else { throw WireError(.invalidSurface, "process: empty input surface") }
                if processor == nil { processor = Processor() }
                dst.buffer = try processor!.process(
                    input, srcRect: .init(x: v[0], y: v[1], width: v[2], height: v[3]), into: dst,
                    dstRect: .init(x: v[4], y: v[5], width: v[6], height: v[7]))

            case .decoderCreate:
                let cid = try r.u32()
                guard let codec = Wire.Codec(rawValue: try r.u32()) else { throw WireError(.unsupportedProfile, "codec") }
                _ = try r.u32()  // width
                _ = try r.u32()  // height
                let depth = Int(try r.u32())
                decoders[cid] = Decoder(codec: codec, bitDepth: depth)

            case .decode:
                let cid = try r.u32(), sid = try r.u32()
                let nParams = Int(try r.u32()), nSlices = Int(try r.u32())
                var params: [UnsafeRawBufferPointer] = []
                var slices: [UnsafeRawBufferPointer] = []
                for _ in 0..<nParams { params.append(try r.bytes(Int(try r.u32()))) }
                for _ in 0..<nSlices { slices.append(try r.bytes(Int(try r.u32()))) }
                guard let dec = decoders[cid] else { throw WireError(.invalidContext, "decoder \(cid)") }
                try dec.decode(params: params, slices: slices, into: try surface(sid, settle: false))
                frames += 1

            case .contextDestroy:
                let cid = try r.u32()
                decoders[cid] = nil
                encoders[cid] = nil

            case .encoderCreate, .encoderConfigure:
                let cid = try r.u32()
                let cfg = try EncoderConfig(&r)
                if let enc = encoders[cid] {
                    try enc.reconfigure(cfg)
                } else {
                    encoders[cid] = try Encoder(cfg)
                }

            case .encode:
                // Answered from the encoder's output callback, so the next requests (decoding
                // the following picture, say) overlap with this encode.
                let cid = try r.u32(), sid = try r.u32()
                let flags = try r.u32()
                guard let enc = encoders[cid] else { throw WireError(.invalidContext, "encoder \(cid)") }
                guard let pb = try surface(sid).buffer else { throw WireError(.invalidSurface, "surface \(sid) is empty") }
                let tag = currentTag
                try enc.encode(pb, forceKey: flags & 1 != 0) { [self] data, key, status in
                    var out = Writer()
                    out.u32(key ? 1 : 0)
                    out.append(data)
                    if status != noErr { log("conn \(id): encode failed (\(status))") }
                    _ = out.data.withUnsafeMutableBytes { b in
                        sendReply(op: raw, tag: tag, status: status == noErr ? .ok : .encodingError,
                                  parts: [iovec(iov_base: b.baseAddress, iov_len: b.count)], length: b.count)
                    }
                }
                frames += 1
                return true

            case .encoderFlush:
                guard let enc = encoders[try r.u32()] else { throw WireError(.invalidContext, "encoder") }
                enc.flush()

            case .bench:
                let n = Int(try r.u32())
                let zeros = Surface.zeroRow(1 << 20)
                var parts: [iovec] = []
                var left = n
                while left > 0 {
                    let c = min(left, 1 << 20)
                    parts.append(iovec(iov_base: zeros, iov_len: c))
                    left -= c
                }
                return sendReply(op: raw, status: .ok, parts: parts, length: n)
            }
        } catch let e as WireError {
            status = e.status
            reply = Writer()
            log("conn \(id): op \(raw): \(e.message)")
        } catch {
            status = .operationFailed
            reply = Writer()
            log("conn \(id): op \(raw): \(error)")
        }
        return reply.data.withUnsafeMutableBytes { b in
            sendReply(op: raw, status: status, parts: [iovec(iov_base: b.baseAddress, iov_len: b.count)], length: b.count)
        }
    }

    /// Looks up a surface. Unless `settle` is false, first waits for a decode still filling it.
    private func surface(_ sid: UInt32, settle: Bool = true) throws -> Surface {
        guard let s = surfaces[sid] else { throw WireError(.invalidSurface, "surface \(sid)") }
        if settle, let d = s.decoding {
            d.waitForFrames()
            s.decoding = nil
        }
        return s
    }

    private func sendReply(op: UInt16, tag: UInt16? = nil, status: Wire.Status, parts: [iovec], length: Int) -> Bool {
        var header = [UInt8](repeating: 0, count: Wire.headerSize)
        header.withUnsafeMutableBytes { h in
            h.storeBytes(of: Wire.magic.littleEndian, toByteOffset: 0, as: UInt32.self)
            h.storeBytes(of: (op | Wire.replyBit).littleEndian, toByteOffset: 4, as: UInt16.self)
            h.storeBytes(of: (tag ?? currentTag).littleEndian, toByteOffset: 6, as: UInt16.self)
            h.storeBytes(of: status.rawValue.littleEndian, toByteOffset: 8, as: UInt32.self)
            h.storeBytes(of: UInt32(length).littleEndian, toByteOffset: 12, as: UInt32.self)
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return false }
        let ok = header.withUnsafeMutableBytes { h in
            writeAll([iovec(iov_base: h.baseAddress, iov_len: Wire.headerSize)] + parts)
        }
        // A half-written reply leaves the stream unusable: end the session at once, so neither
        // side (nor the vsock relay between them) is left blocked on it.
        if !ok { shutdown(fd, SHUT_RDWR) }
        return ok
    }

    /// Ends the session: no reply may be written after this, even by a late encoder callback.
    private func markClosed() {
        writeLock.lock()
        closed = true
        writeLock.unlock()
    }

    /// Reads exactly `n` bytes. With `timeout`, the bytes must keep arriving: a client that
    /// stalls mid-message for `Connection.ioTimeout` seconds is dropped.
    private func readFully(_ p: UnsafeMutableRawPointer, _ n: Int, timeout: Bool = false) -> Bool {
        var got = 0
        while got < n {
            if timeout {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, Int32(Connection.ioTimeout * 1000))
                if ready == 0 {
                    log("conn \(id): client stalled mid-request, closing")
                    return false
                }
                if ready < 0 { if errno == EINTR { continue } else { return false } }
            }
            let r = read(fd, p + got, n - got)
            if r > 0 { got += r; continue }
            if r < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }

    private func writeAll(_ parts: [iovec]) -> Bool {
        var iov = parts.filter { $0.iov_len > 0 }
        var start = 0
        while start < iov.count {
            let n = min(iov.count - start, Int(IOV_MAX))
            let w = iov.withUnsafeMutableBufferPointer { writev(fd, $0.baseAddress! + start, Int32(n)) }
            if w < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    log("conn \(id): client stopped reading replies for \(Connection.ioTimeout)s, closing")
                }
                return false
            }
            var left = w
            while left > 0, start < iov.count {
                if left >= iov[start].iov_len {
                    left -= iov[start].iov_len
                    start += 1
                } else {
                    iov[start].iov_base += left
                    iov[start].iov_len -= left
                    left = 0
                }
            }
        }
        return true
    }
}
