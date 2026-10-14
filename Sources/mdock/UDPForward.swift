import Foundation

/// A published UDP port on the Mac. Each client address gets its own flow to the container: a UDP
/// socket aimed at the guest's IP (direct), or a vsock stream to mdock-guestd carrying datagrams as
/// [2-byte big-endian length][payload] (relay). Flows idle for two minutes are closed. `cancel`
/// stops the whole forward.
final class UDPForward {
    enum Upstream {
        case direct(ip: String)
        case relay(connect: (UInt16) -> Int32?)
    }

    private final class Flow {
        let fd: Int32
        let framed: Bool
        var lastActive = Date()
        var closed = false
        init(fd: Int32, framed: Bool) {
            self.fd = fd
            self.framed = framed
        }
    }

    let cancel = Cancel()
    private let listener: Int32
    private let port: UInt16
    private let upstream: Upstream
    private let lock = NSLock()
    private var flows: [Data: Flow] = [:]

    /// Bound to every interface in place of loopback (macOS reserves low loopback ports for root):
    /// datagrams from other machines are dropped.
    private let loopbackOnly: Bool

    init(host: String?, port: UInt16, upstream: Upstream, loopbackOnly: Bool = false) throws {
        listener = try Sockets.udpBind(host: host, port: port)
        self.loopbackOnly = loopbackOnly
        self.port = port
        self.upstream = upstream
        Thread.detachNewThread { [self] in receiveLoop() }
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 2 + 65_535)
        var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        var lastSweep = Date()
        while !cancel.isSet {
            if Date().timeIntervalSince(lastSweep) > 30 {
                sweep(idleFor: 120)
                lastSweep = Date()
            }
            guard poll(&pfd, 1, 250) > 0 else { continue }
            var addr = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(listener, raw.baseAddress! + 2, 65_535, 0, $0, &len) }
                }
            }
            guard n >= 0 else { continue }
            if loopbackOnly, !withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Sockets.isLoopback($0) } }) {
                continue
            }
            guard let flow = flow(for: addr, len) else { continue }
            lock.withLock { flow.lastActive = Date() }
            if flow.framed {
                buffer[0] = UInt8(n >> 8)
                buffer[1] = UInt8(n & 0xff)
                if !buffer.withUnsafeBytes({ Sockets.writeAll(flow.fd, $0.baseAddress!, n + 2) }) { end(flow) }
            } else {
                _ = buffer.withUnsafeBytes { send(flow.fd, $0.baseAddress! + 2, n, 0) }
            }
        }
        close(listener)
        sweep(idleFor: -1)
    }

    private func flow(for addr: sockaddr_storage, _ len: socklen_t) -> Flow? {
        var addr = addr
        let key = withUnsafeBytes(of: &addr) { Data($0.prefix(Int(len))) }
        if let flow = lock.withLock({ flows[key] }) { return flow }
        let flow: Flow
        switch upstream {
        case .direct(let ip):
            guard let fd = Sockets.udpConnect(host: ip, port: port) else { return nil }
            flow = Flow(fd: fd, framed: false)
        case .relay(let connect):
            guard let fd = connect(port) else { return nil }
            flow = Flow(fd: fd, framed: true)
        }
        lock.withLock { flows[key] = flow }
        Thread.detachNewThread { [self] in replyLoop(flow, to: addr, len) }
        return flow
    }

    /// Container -> client: datagrams (or frames) from the flow's upstream go back to the client.
    private func replyLoop(_ flow: Flow, to addr: sockaddr_storage, _ len: socklen_t) {
        var addr = addr
        var buffer = [UInt8](repeating: 0, count: 65_535)
        while true {
            var n: Int
            if flow.framed {
                var header = [UInt8](repeating: 0, count: 2)
                guard Sockets.readFull(flow.fd, &header, 2) else { break }
                n = Int(header[0]) << 8 | Int(header[1])
                guard Sockets.readFull(flow.fd, &buffer, n) else { break }
            } else {
                n = recv(flow.fd, &buffer, buffer.count, 0)
                if n < 0, errno == EINTR || errno == ECONNREFUSED { continue }
                if n < 0 || (n == 0 && lock.withLock({ flow.closed })) { break }
            }
            lock.withLock { flow.lastActive = Date() }
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(listener, buffer, n, 0, $0, len) }
            }
        }
        end(flow)
        close(flow.fd)
    }

    /// Shuts a flow down (its reply loop closes the descriptor) and forgets it.
    private func end(_ flow: Flow) {
        let first = lock.withLock { () -> Bool in
            defer { flow.closed = true }
            if let key = flows.first(where: { $0.value === flow })?.key { flows.removeValue(forKey: key) }
            return !flow.closed
        }
        if first { Sockets.shutdownBoth(flow.fd) }
    }

    private func sweep(idleFor seconds: TimeInterval) {
        let idle = lock.withLock { flows.values.filter { seconds < 0 || Date().timeIntervalSince($0.lastActive) > seconds } }
        idle.forEach(end)
    }
}
