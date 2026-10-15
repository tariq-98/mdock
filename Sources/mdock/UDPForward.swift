import Foundation

/// A published UDP port on the Mac. Each client address gets its own flow to the container: a vsock
/// stream to mdock-guestd carrying datagrams as [2-byte big-endian length][payload]. Flows idle for
/// two minutes are closed. `cancel` stops the whole forward.
final class UDPForward {
    private final class Flow {
        let fd: Int32
        var lastActive = Date()
        var closed = false
        init(fd: Int32) { self.fd = fd }
    }

    let cancel = Cancel()
    private let listener: Int32
    private let port: UInt16
    /// Opens a flow's stream to the guest for a port.
    private let connect: (UInt16) -> Int32?
    private let lock = NSLock()
    private var flows: [Data: Flow] = [:]

    /// Bound to every interface in place of loopback (macOS reserves low loopback ports for root):
    /// datagrams from other machines are dropped.
    private let loopbackOnly: Bool

    init(host: String?, port: UInt16, connect: @escaping (UInt16) -> Int32?, loopbackOnly: Bool = false) throws {
        listener = try Sockets.udpBind(host: host, port: port)
        self.loopbackOnly = loopbackOnly
        self.port = port
        self.connect = connect
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
            buffer[0] = UInt8(n >> 8)
            buffer[1] = UInt8(n & 0xff)
            if !buffer.withUnsafeBytes({ Sockets.writeAll(flow.fd, $0.baseAddress!, n + 2) }) { end(flow) }
        }
        close(listener)
        sweep(idleFor: -1)
    }

    private func flow(for addr: sockaddr_storage, _ len: socklen_t) -> Flow? {
        var addr = addr
        let key = withUnsafeBytes(of: &addr) { Data($0.prefix(Int(len))) }
        if let flow = lock.withLock({ flows[key] }) { return flow }
        guard let fd = connect(port) else { return nil }
        let flow = Flow(fd: fd)
        lock.withLock { flows[key] = flow }
        Thread.detachNewThread { [self] in replyLoop(flow, to: addr, len) }
        return flow
    }

    /// Container -> client: frames from the flow's stream go back to the client as datagrams.
    private func replyLoop(_ flow: Flow, to addr: sockaddr_storage, _ len: socklen_t) {
        var addr = addr
        var buffer = [UInt8](repeating: 0, count: 65_535)
        while true {
            var header = [UInt8](repeating: 0, count: 2)
            guard Sockets.readFull(flow.fd, &header, 2) else { break }
            let n = Int(header[0]) << 8 | Int(header[1])
            guard Sockets.readFull(flow.fd, &buffer, n) else { break }
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
