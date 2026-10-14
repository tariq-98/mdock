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
    var busy: String?
    var message: String?
    var gpuReport: String?
    var config: [String: Any] = [:]

    var running: Bool { status?.ready == true }
    var configuredGPU: Bool { config["gpuEngine"] as? Bool ?? false }

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
        let visible = NSApp.windows.contains { $0.isVisible && !String(describing: type(of: $0)).contains("StatusBar") }
        if !visible && !containers.isEmpty && status != nil {
            Task.detached(priority: .utility) {
                let status = Backend.status()
                await MainActor.run { self.status = status }
            }
            return
        }
        Task.detached(priority: .utility) {
            let status = Backend.status()
            let config = Backend.config()
            let ready = status?.ready == true
            let containers = ready ? Backend.dockerJSON("/containers/json?all=1", as: [Container].self) ?? [] : []
            let images = ready ? Backend.dockerJSON("/images/json", as: [DockerImage].self) ?? [] : []
            let gpu = Set(containers.filter(\.running).filter {
                Backend.dockerJSON("/containers/\($0.Id)/json", as: ContainerDetail.self)?.usesGPU == true
            }.map(\.Id))
            await MainActor.run {
                self.status = status
                self.config = config
                self.containers = containers.sorted { $0.Created > $1.Created }
                self.images = images.sorted { $0.Created > $1.Created }
                self.gpuContainers = gpu
            }
        }
    }

    // MARK: VM

    func start(gpu: Bool) {
        perform(gpu ? "Starting with GPU…" : "Starting…") { await Backend.runCLI(["start", gpu ? "--gpu" : "--no-gpu"]) }
    }

    func stop() {
        perform("Stopping…") { await Backend.runCLI(["stop"]) }
    }

    func switchEngine(gpu: Bool) {
        perform(gpu ? "Restarting with GPU…" : "Restarting without GPU…") {
            _ = await Backend.runCLI(["stop"])
            return await Backend.runCLI(["start", gpu ? "--gpu" : "--no-gpu"])
        }
    }

    func set(_ key: String, _ value: String) {
        perform("Saving…") { await Backend.runCLI(["set", "\(key)=\(value)"]) }
    }

    func checkGPU() {
        gpuReport = nil
        perform("Probing the GPU from a container…") {
            let result = await Backend.runCLI(["gpu-check"])
            await MainActor.run { self.gpuReport = result.output }
            return result
        }
    }

    // MARK: Docker

    func container(_ id: String, _ action: String) {
        perform("\(action.capitalized)…") {
            let r = Backend.docker("POST", "/containers/\(id)/\(action)")
            return (r.map { $0.status < 300 } ?? false, r.map { String(decoding: $0.body, as: UTF8.self) } ?? "no response")
        }
    }

    func remove(container id: String) {
        perform("Removing…") {
            let r = Backend.docker("DELETE", "/containers/\(id)?force=1")
            return (r.map { $0.status < 300 } ?? false, r.map { String(decoding: $0.body, as: UTF8.self) } ?? "no response")
        }
    }

    func remove(image id: String) {
        perform("Removing image…") {
            let r = Backend.docker("DELETE", "/images/\(id)")
            return (r.map { $0.status < 300 } ?? false, r.map { String(decoding: $0.body, as: UTF8.self) } ?? "no response")
        }
    }

    func open(port: Int) {
        NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!)
    }

    private func perform(_ label: String, _ work: @escaping @Sendable () async -> (ok: Bool, output: String)) {
        busy = label
        message = nil
        Task {
            let result = await Task.detached { await work() }.value
            busy = nil
            if !result.ok { message = result.output.isEmpty ? "Failed" : result.output }
            refresh()
        }
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
