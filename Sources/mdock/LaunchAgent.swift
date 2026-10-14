import Foundation

/// `mdock autostart on` runs the daemon under launchd: it starts at login, and comes back if it
/// crashes or the VM goes down unexpectedly. A requested stop exits with status 0, which KeepAlive
/// leaves stopped until the next login or `mdock start`.
enum LaunchAgent {
    static let label = "local.mdock.daemon"
    static let plist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    static var domain: String { "gui/\(getuid())" }
    static var target: String { "\(domain)/\(label)" }
    static var installed: Bool { FileManager.default.fileExists(atPath: plist.path) }
    /// launchd sets XPC_SERVICE_NAME to the job's label in the processes it starts.
    static var supervising: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }
    static var loaded: Bool { (try? run("/bin/launchctl", ["print", target], quiet: true)) != nil }

    static func install() throws {
        try writePlist()
        // A loaded job keeps its old definition; reload it unless it is running the VM right now.
        if loaded, status() == nil { _ = try? run("/bin/launchctl", ["bootout", target], quiet: true) }
    }

    /// The job as this build defines it (start() rewrites it, so upgrades pick up new keys).
    static func writePlist() throws {
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "daemon"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            // Room for a graceful guest shutdown at logout before launchd escalates to SIGKILL.
            "ExitTimeOut": 75,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": Paths.daemonLog.path,
            "StandardErrorPath": Paths.daemonLog.path,
            "EnvironmentVariables": ["PATH": "\(home)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"],
            // launchd holds docker.sock: after an idle stop, the next docker command starts mdock again.
            "Sockets": ["docker": ["SockPathName": Paths.dockerSocket.path, "SockPathMode": 384]],
        ]
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist, options: .atomic)
    }

    /// Removes the agent. A job that is running the VM stays until it stops (or the user logs out),
    /// so turning autostart off never takes the VM down.
    static func remove() {
        try? FileManager.default.removeItem(at: plist)
        if loaded, status() == nil { _ = try? run("/bin/launchctl", ["bootout", target], quiet: true) }
    }

    /// Starts the daemon under launchd: kickstart a loaded job, otherwise load it (RunAtLoad starts it).
    static func start() throws {
        try? FileManager.default.removeItem(at: Paths.starts)
        try writePlist()
        // Reload, so launchd runs the plist as it is now (it isn't running the VM at this point).
        if loaded { _ = try? run("/bin/launchctl", ["bootout", target], quiet: true) }
        // launchd may still be tearing the old job down (its daemon just exited); retry briefly.
        for attempt in 0..<20 {
            do {
                try run("/bin/launchctl", ["bootstrap", domain, plist.path], quiet: true)
                return
            } catch where attempt < 19 {
                usleep(250_000)
            }
        }
    }

    /// `mdock stop`: unload the job, which also closes launchd's docker.sock so nothing starts the VM
    /// again until `mdock start` (or the next login). A running daemon gets SIGTERM: a clean stop.
    static func unload() {
        if loaded { _ = try? run("/bin/launchctl", ["bootout", target], quiet: true) }
        try? FileManager.default.removeItem(at: Paths.idleMarker)
    }

    /// Stopped after being idle, with launchd waiting on docker.sock to start it again.
    static var idleStopped: Bool {
        FileManager.default.fileExists(atPath: Paths.idleMarker.path) && !FileManager.default.fileExists(atPath: Paths.pid.path) && loaded
    }

    /// The listening socket launchd holds for this job, when launchd started us through it.
    static func activatedSocket(_ name: String) -> Int32? {
        typealias Activate = @convention(c) (UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>,
                                             UnsafeMutablePointer<Int>) -> Int32
        guard supervising, let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "launch_activate_socket") else { return nil }
        var fds: UnsafeMutablePointer<Int32>?
        var count = 0
        guard unsafeBitCast(symbol, to: Activate.self)(name, &fds, &count) == 0, count > 0, let fds else { return nil }
        defer { free(fds) }
        return fds[0]
    }

    /// Records a supervised start and reports a crash loop: 5 starts within 5 minutes. The daemon then
    /// exits 0 so launchd stops retrying until the next `mdock start`.
    static func crashLooping() -> Bool {
        let now = Date().timeIntervalSince1970
        let recent = ((try? String(contentsOf: Paths.starts, encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { Double($0) }.filter { now - $0 < 300 } + [now]
        try? recent.map { String(Int($0)) }.joined(separator: "\n").write(to: Paths.starts, atomically: true, encoding: .utf8)
        return recent.count > 5
    }
}
