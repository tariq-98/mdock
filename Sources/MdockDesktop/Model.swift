import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class Model {
    var status: DaemonStatus?
    var containers: [Container] = []
    var images: [DockerImage] = []
    var gpuContainers: Set<String> = []
    /// What's happening right now, for the activity banner ("Booting the Linux VM…").
    var busy: String?
    /// A start, stop or engine switch in progress ("Starting"): the VM itself is changing state.
    var transition: String?
    var message: String?
    var gpuReport: String?
    var config: [String: Any] = [:]
    /// Stopped by idle stop, with launchd waiting to start it again on the next docker command.
    var idleStopped = false

    /// Docker is ready. Kept apart from `status`, which is only refreshed while a window is on screen:
    /// the menu bar icon needs nothing else.
    private(set) var running = false
    var configuredGPU: Bool { config["gpuEngine"] as? Bool ?? false }
    var idleMinutes: Int { config["idleMinutes"] as? Int ?? 10 }
    var runningContainers: [Container] { containers.filter(\.running) }

    enum Phase: Equatable {
        case running, stopped, idle, working(String)

        var title: String {
            switch self {
            case .running: "Running"
            case .stopped, .idle: "Stopped"
            case .working(let title): title
            }
        }
    }

    var phase: Phase {
        if let transition { return .working(transition) }
        if running { return .running }
        return idleStopped ? .idle : .stopped
    }

    /// One plain sentence about the state, for the overview and the menu bar panel.
    var summary: String {
        switch phase {
        case .running:
            let engine = status?.isGPU == true ? "the GPU engine" : "the default engine"
            let count = runningContainers.count
            let containers = count == 0 ? "No containers are running." : count == 1 ? "1 container is running." : "\(count) containers are running."
            return "Docker is ready on \(engine). \(containers)"
        case .stopped:
            return "Start mdock to run containers."
        case .idle:
            return "mdock stopped after \(idleMinutes) idle minutes to free memory. Your next docker command starts it again."
        case .working:
            return busy ?? ""
        }
    }

    /// Memory in GiB: used by Linux, held by the VM right now, and the most the VM can have.
    var memory: (used: Double, held: Double, total: Double)? {
        guard let s = status, s.ready else { return nil }
        let used = Double(max(0, s.guestMemTotalMiB - s.guestMemAvailableMiB)) / 1024
        let total = Double(s.memoryGiB)
        let held = min(total, Double(s.balloonMiB) / 1024)
        return (used, max(used, held), total)
    }

    private var timer: Timer?
    /// Docker's event stream is being read (Backend.watchEvents).
    private var watching = false
    private var reloadPending = false
    /// When containers and images were last read.
    private var loadedAt = Date.distantPast
    private var ticks = 0

    init() {
        Task { await reload() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Every 2 s the daemon's status, from its control socket: Docker isn't involved. Containers and
    /// images are read again only when Docker reports a change (and every 30 s while a window is on
    /// screen, for "Up 5 minutes"). Listing them every 2 s kept dockerd and containerd waking each
    /// other across every vCPU, which tripled mdock's idle CPU use.
    func refresh() {
        // NSApp is still nil when SwiftUI creates the model at launch: no window is open yet.
        let onScreen = NSApp?.windows.contains {
            $0.isVisible && $0.occlusionState.contains(.visible) && !String(describing: type(of: $0)).contains("StatusBar")
        } ?? false
        if onScreen && Date().timeIntervalSince(loadedAt) > 30 { scheduleReload() }
        // Off screen, only the menu bar icon shows the state: every 10 s is enough (this app's own
        // starts and stops update at once).
        ticks += 1
        guard onScreen || ticks % 5 == 0 else { return }
        Task.detached(priority: .utility) {
            let status = Backend.status()
            let idle = status == nil && Backend.idleStopped
            await MainActor.run {
                let ready = status?.ready == true
                let started = ready && !self.running
                // Off screen, only what the menu bar icon shows changes: a new status every 2 s had SwiftUI
                // lay out windows nobody was looking at.
                if onScreen || ready != self.running { self.status = status }
                if ready != self.running { self.running = ready }
                if idle != self.idleStopped { self.idleStopped = idle }
                if started { self.scheduleReload() }
                if ready { self.watchEvents() }
            }
        }
    }

    /// Reads Docker's events until the stream ends (the VM stopped); the timer starts it again.
    private func watchEvents() {
        guard !watching else { return }
        watching = true
        Thread.detachNewThread { [weak self] in
            Backend.watchEvents { Task { @MainActor in self?.scheduleReload() } }
            Task { @MainActor in self?.watching = false }
        }
    }

    /// One reload for a burst of events (a compose project starting, say).
    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            reloadPending = false
            await reload()
        }
    }

    /// Everything the windows show, read off the main thread.
    func reload() async {
        loadedAt = Date()
        let snapshot = await Task.detached(priority: .utility) { Snapshot.load() }.value
        status = snapshot.status
        running = snapshot.status?.ready == true
        containers = snapshot.containers.sorted { $0.Created > $1.Created }
        images = snapshot.images.sorted { $0.Created > $1.Created }
        gpuContainers = snapshot.gpuContainers
        idleStopped = snapshot.idleStopped
        config = Backend.config()
    }

    // MARK: VM

    func start(gpu: Bool) {
        perform(gpu ? "Booting the Linux VM on the GPU engine…" : "Booting the Linux VM…", transition: "Starting") {
            await Backend.runCLI(["start", gpu ? "--gpu" : "--no-gpu"])
        }
    }

    func stop() {
        perform("Shutting the VM down…", transition: "Stopping") { await Backend.runCLI(["stop"]) }
    }

    func switchEngine(gpu: Bool) {
        perform(gpu ? "Restarting on the GPU engine…" : "Restarting on the default engine…", transition: "Restarting") {
            _ = await Backend.runCLI(["stop"])
            return await Backend.runCLI(["start", gpu ? "--gpu" : "--no-gpu"])
        }
    }

    func set(_ key: String, _ value: String) {
        perform("Saving the setting…") { await Backend.runCLI(["set", "\(key)=\(value)"]) }
    }

    func checkGPU() {
        gpuReport = nil
        perform("Checking the GPU from a container…") {
            let result = await Backend.runCLI(["gpu-check"])
            await MainActor.run { self.gpuReport = result.output }
            return result
        }
    }

    // MARK: Docker

    func container(_ id: String, _ action: String) {
        let verb = ["start": "Starting", "stop": "Stopping", "restart": "Restarting"][action] ?? action.capitalized
        perform("\(verb) \(name(of: id))…") {
            let r = Backend.docker("POST", "/containers/\(id)/\(action)")
            return (r.map { $0.status < 300 } ?? false, r.map { String(decoding: $0.body, as: UTF8.self) } ?? "No response from Docker")
        }
    }

    func remove(container id: String) {
        perform("Removing \(name(of: id))…") {
            let r = Backend.docker("DELETE", "/containers/\(id)?force=1")
            return (r.map { $0.status < 300 } ?? false, r.map { String(decoding: $0.body, as: UTF8.self) } ?? "No response from Docker")
        }
    }

    func remove(image id: String) {
        perform("Removing the image…") {
            let r = Backend.docker("DELETE", "/images/\(id)")
            return (r.map { $0.status < 300 } ?? false, r.map { String(decoding: $0.body, as: UTF8.self) } ?? "No response from Docker")
        }
    }

    func open(port: Int) {
        guard let url = URL(string: "http://localhost:" + String(port)) else { return }
        NSWorkspace.shared.open(url)
    }

    private func name(of id: String) -> String {
        containers.first { $0.Id == id }?.name ?? "the container"
    }

    private func perform(_ label: String, transition: String? = nil,
                         _ work: @escaping @Sendable () async -> (ok: Bool, output: String)) {
        busy = label
        self.transition = transition
        message = nil
        Task {
            let result = await Task.detached { await work() }.value
            // Read the new state before clearing the transition, so the box doesn't flick back.
            await reload()
            busy = nil
            self.transition = nil
            if !result.ok { message = result.output.isEmpty ? "That didn't work, and mdock gave no reason." : result.output }
        }
    }
}

/// One read of the daemon and Docker.
struct Snapshot: Sendable {
    var status: DaemonStatus?
    var containers: [Container] = []
    var images: [DockerImage] = []
    var gpuContainers: Set<String> = []
    var idleStopped = false

    static func load() -> Snapshot {
        let status = Backend.status()
        guard status?.ready == true else { return Snapshot(status: status, idleStopped: status == nil && Backend.idleStopped) }
        // mdock's internal socket: looking at the app doesn't count as using Docker, so it never keeps
        // the VM from stopping when idle.
        let socket = Backend.internalSocket
        let containers = Backend.dockerJSON("/containers/json?all=1", as: [Container].self, socket: socket) ?? []
        let images = Backend.dockerJSON("/images/json", as: [DockerImage].self, socket: socket) ?? []
        let gpu = Set(containers.filter(\.running).filter {
            Backend.dockerJSON("/containers/\($0.Id)/json", as: ContainerDetail.self, socket: socket)?.usesGPU == true
        }.map(\.Id))
        return Snapshot(status: status, containers: containers, images: images, gpuContainers: gpu)
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
