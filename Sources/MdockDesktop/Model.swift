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

    var running: Bool { status?.ready == true }
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

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        // Containers and images only while a window is open: listing them every 2 s keeps dockerd and
        // containerd waking each other across every vCPU, which costs the Mac real CPU when idle.
        // NSApp is still nil when SwiftUI creates the model at launch: no window is open yet.
        let visible = NSApp?.windows.contains { $0.isVisible && !String(describing: type(of: $0)).contains("StatusBar") } ?? false
        if !visible && !containers.isEmpty && status != nil {
            Task.detached(priority: .utility) {
                let status = Backend.status()
                let idle = status == nil && Backend.idleStopped
                await MainActor.run {
                    self.status = status
                    self.idleStopped = idle
                }
            }
            return
        }
        Task { await reload() }
    }

    /// Everything the windows show, read off the main thread.
    func reload() async {
        let snapshot = await Task.detached(priority: .utility) { Snapshot.load() }.value
        status = snapshot.status
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
        let containers = Backend.dockerJSON("/containers/json?all=1", as: [Container].self) ?? []
        let images = Backend.dockerJSON("/images/json", as: [DockerImage].self) ?? []
        let gpu = Set(containers.filter(\.running).filter {
            Backend.dockerJSON("/containers/\($0.Id)/json", as: ContainerDetail.self)?.usesGPU == true
        }.map(\.Id))
        return Snapshot(status: status, containers: containers, images: images, gpuContainers: gpu)
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
