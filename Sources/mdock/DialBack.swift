import Foundation

/// Streams into the guest over the VM's own network: published TCP ports and the Docker API. Their
/// bytes skip vsock (~0.6 GB/s through one serial queue per VM) for vmnet (several GB/s), and TCP's
/// flow control works end to end, so a slow reader slows the sender down; over vsock the Mac must
/// drain the guest's data whatever the reader does (Sockets.splice).
///
/// The Mac never dials into the VM: macOS's Local Network privacy forbids that to a daemon run by
/// launchd until someone allows it, but accepting connections from the VM needs no permission. So for
/// each connection the Mac asks mdock-guestd, over a vsock control stream, to connect to the target in
/// the guest and then dial back to a listener on the Mac's address on the VM's network. (Velox does
/// the same for ports with a pool of connections dialed ahead of time.)
///
/// Every request carries a random id, and a connection is spliced to a client only once it has sent
/// an id the Mac is waiting for, so nothing else on that network (another VM, a container) can attach
/// itself to a client.
///
/// The same listener takes host.docker.internal connections from mdock-guestd: "<secret> <port>", the
/// secret a random value it got over vsock, kept where containers can't read it (the guest's /run).
final class DialBack {
    enum Outcome {
        case connected(Int32)
        /// Nothing listens on the target in the guest.
        case refused
        /// The guest didn't connect back in time, or its end of the control stream is gone.
        case unavailable
    }

    private final class Request {
        let done = DispatchSemaphore(value: 0)
        var fd: Int32 = -1
        var refused = false
    }

    /// The Mac's address on the VM's network, where the guest dials back.
    let address: String
    /// What a host.docker.internal connection from mdock-guestd starts with.
    private let secret = DialBack.newID()
    /// Takes a host.docker.internal connection for a port on the Mac.
    private let hostForward: (Int32, UInt16) -> Void
    private let control: Int32
    private let listener: Int32
    private let guest: in_addr_t
    private let lock = NSLock()
    private var pending: [String: Request] = [:]
    private var closed = false
    private let stopAccepting = Cancel()
    /// Accepted connections that haven't sent their id yet.
    private var unidentified = 0

    var isClosed: Bool { lock.withLock { closed } }

    private init(address: String, control: Int32, listener: Int32, guest: in_addr_t, hostForward: @escaping (Int32, UInt16) -> Void) {
        self.address = address
        self.control = control
        self.listener = listener
        self.guest = guest
        self.hostForward = hostForward
    }

    /// Listens on the Mac's address in the guest's subnet and tells mdock-guestd about it over the
    /// stream `connect` opens. Nil when the Mac has no address there or the guest doesn't take it.
    static func start(guestIP: String, connect: () -> Int32?, hostForward: @escaping (Int32, UInt16) -> Void) -> DialBack? {
        var guest = in_addr()
        guard inet_pton(AF_INET, guestIP, &guest) == 1, let local = localAddress(sameSubnetAs: guest.s_addr) else { return nil }
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_addr.s_addr = local
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, length) == 0 && listen(listener, 256) == 0 && getsockname(listener, $0, &length) == 0
            }
        }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard listening, inet_ntop(AF_INET, &sin.sin_addr, &text, socklen_t(text.count)) != nil, let control = connect() else {
            close(listener)
            return nil
        }
        // A guest that stops reading its control stream must not hang every new connection.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(control, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let address = String(cString: text)
        let dialBack = DialBack(address: address, control: control, listener: listener, guest: guest.s_addr, hostForward: hostForward)
        guard writeAll(control, "\(address) \(UInt16(bigEndian: sin.sin_port)) \(dialBack.secret)\n") else {
            close(control)
            close(listener)
            return nil
        }
        Thread.detachNewThread { dialBack.readReplies() }
        Sockets.acceptLoop(listener, cancel: dialBack.stopAccepting) { dialBack.admit($0) }
        return dialBack
    }

    /// A connection to `target` in the guest, dialed back over the VM's network: a port on the guest's
    /// loopback, or "unix:<path>".
    func connect(_ target: String, timeout: DispatchTimeInterval = .seconds(1)) -> Outcome {
        let id = Self.newID()
        let request = Request()
        let sent = lock.withLock { () -> Bool in
            guard !closed else { return false }
            pending[id] = request
            guard Self.writeAll(control, "\(id) \(target)\n") else {
                pending[id] = nil
                return false
            }
            return true
        }
        guard sent else { return .unavailable }
        if request.done.wait(timeout: .now() + timeout) == .timedOut {
            // From here on a connection with this id finds no request and is closed; one that got in
            // first is ours.
            guard lock.withLock({ pending.removeValue(forKey: id) }) == nil else { return .unavailable }
            request.done.wait()
        }
        if request.fd >= 0 { return .connected(request.fd) }
        return request.refused ? .refused : .unavailable
    }

    /// Hands a request its outcome, once: false if it had already been settled or given up on.
    @discardableResult
    private func resolve(_ id: String, fd: Int32, refused: Bool = false) -> Bool {
        guard let request = lock.withLock({ pending.removeValue(forKey: id) }) else { return false }
        request.fd = fd
        request.refused = refused
        request.done.signal()
        return true
    }

    /// The guest's replies, "<id> refused" or "<id> unreachable", read continuously as every vsock
    /// stream must be.
    private func readReplies() {
        while let line = Sockets.readLine(control, limit: 64) {
            let words = line.split(separator: " ")
            if words.count == 2 { resolve(String(words[0]), fd: -1, refused: words[1] == "refused") }
        }
        let waiting = lock.withLock { () -> [Request] in
            closed = true
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        waiting.forEach { $0.done.signal() }
        stopAccepting.set()
        close(control)  // nothing writes to it once `closed` is set
    }

    /// A connection to the listener: spliced to its client once it sends a pending id.
    private func admit(_ fd: Int32) {
        // Only the guest dials back.
        var peer = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &length) == 0 }
        }
        guard named && peer.sin_addr.s_addr == guest else {
            close(fd)
            return
        }
        // The guest sends its id as soon as it connects, so it has usually arrived already: taking it
        // here saves starting a thread for each connection.
        if Sockets.wait(fd, POLLIN, timeout: 0), let id = Self.takeLine(fd) {
            identified(fd, id)
            return
        }
        // Only so many connections may be waiting to say who they are.
        guard lock.withLock({ () -> Bool in
            guard unidentified < 64 else { return false }
            unidentified += 1
            return true
        }) else {
            close(fd)
            return
        }
        Thread.detachNewThread { [self] in
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let id = Sockets.readLine(fd, limit: 80)
            lock.withLock { unidentified -= 1 }
            timeout = timeval()
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard let id else {
                close(fd)
                return
            }
            identified(fd, id)
        }
    }

    private func identified(_ fd: Int32, _ line: String) {
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        let words = line.split(separator: " ")
        if words.count == 2, words[0] == secret, let port = UInt16(words[1]), port > 0 {
            Thread.detachNewThread { [self] in hostForward(fd, port) }
            return
        }
        if !resolve(line, fd: fd) { close(fd) }
    }

    /// The first line on `fd` if all of it has arrived, taken without anything after it (which
    /// belongs to the stream: a server may speak first).
    private static func takeLine(_ fd: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = recv(fd, &buffer, buffer.count, MSG_PEEK)
        guard n > 0, let newline = buffer[..<n].firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        guard recv(fd, &buffer, newline + 1, 0) == newline + 1 else { return nil }
        return String(decoding: buffer[..<newline], as: UTF8.self)
    }

    private static func writeAll(_ fd: Int32, _ string: String) -> Bool {
        let bytes = Array(string.utf8)
        return bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    private static func newID() -> String {
        var random = SystemRandomNumberGenerator()
        return String(format: "%016llx%016llx", random.next() as UInt64, random.next() as UInt64)
    }

    /// The Mac's own IPv4 address on the subnet `guest` is in (vmnet's bridge, such as 192.168.64.1).
    private static func localAddress(sameSubnetAs guest: in_addr_t) -> in_addr_t? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let address = interface.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let netmask = interface.ifa_netmask else { continue }
            let local = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if mask != 0 && local != guest && local & mask == guest & mask { return local }
        }
        return nil
    }
}
