import AppKit
import SwiftUI

/// The panel under the menu bar glyph: the box and the state, memory, what's running, and the
/// actions you reach for most.
struct MenuPanel: View {
    @Environment(Model.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let memory = model.memory {
                Divider().padding(.horizontal, 14)
                memoryRow(memory)
                Divider().padding(.horizontal, 14)
                running
            }
            Divider().padding(.horizontal, 14)
            actions
            Divider().padding(.horizontal, 14)
            VStack(spacing: 0) {
                Button(action: openDashboard) { MenuLabel("Open dashboard", systemImage: "macwindow") }
                    .keyboardShortcut("o")
                Button { NSApp.terminate(nil) } label: { MenuLabel("Quit mdock Desktop") }
                    .keyboardShortcut("q")
                    .help("Quits this app. mdock keeps running.")
            }
            .padding(6)
        }
        .buttonStyle(MenuRowStyle())
        .frame(width: 330)
    }

    private var header: some View {
        HStack(spacing: 14) {
            BoxIllustration(phase: model.phase, shadowRadius: 5)
                .frame(width: 52, height: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.phase.title)
                    .font(.system(size: 18, weight: .semibold).width(.expanded))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var subtitle: String {
        switch model.phase {
        case .running: model.status?.isGPU == true ? "On the GPU engine" : "On the default engine"
        case .stopped: "Start it to run containers."
        case .idle: "Stopped while idle. Your next docker command starts it again."
        case .working: model.busy ?? ""
        }
    }

    private func memoryRow(_ memory: (used: Double, held: Double, total: Double)) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Memory").foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f of %d GiB", memory.used, Int(memory.total))).monospacedDigit()
            }
            MemoryBar(used: memory.used, held: memory.held, total: memory.total)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var running: some View {
        let containers = model.runningContainers
        return VStack(alignment: .leading, spacing: 6) {
            Text("Running now")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            if containers.isEmpty {
                Text("No containers are running.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(containers.prefix(6)) { container in
                    HStack(spacing: 9) {
                        PaperBox().frame(width: 15, height: 15)
                        Text(container.name).lineLimit(1)
                        if model.gpuContainers.contains(container.Id) { Tag("GPU") }
                        Spacer(minLength: 8)
                        ForEach(container.publishedTCP.prefix(2), id: \.self) { port in
                            let address = "localhost:" + String(port)
                            Button(address) { model.open(port: port) }
                                .buttonStyle(.link)
                                .font(.system(.callout, design: .monospaced))
                                .help("Open http://" + address)
                        }
                    }
                    .padding(.vertical, 2)
                }
                if containers.count > 6 {
                    Text("And \(containers.count - 6) more in the dashboard.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .running:
                let gpu = model.status?.isGPU == true
                Button { model.stop() } label: { MenuLabel("Stop mdock", systemImage: "stop.fill") }
                Button { model.switchEngine(gpu: !gpu) } label: {
                    MenuLabel(gpu ? "Switch to default engine" : "Switch to GPU engine", systemImage: "arrow.triangle.2.circlepath")
                }
            case .stopped, .idle:
                Button { model.start(gpu: model.configuredGPU) } label: { MenuLabel("Start mdock", systemImage: "play.fill") }
                Button { model.start(gpu: !model.configuredGPU) } label: {
                    MenuLabel(model.configuredGPU ? "Start on default engine" : "Start with GPU", systemImage: "cpu")
                }
            case .working:
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small).frame(width: 16)
                    Text(model.busy ?? "")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
        }
        .padding(6)
        .disabled(model.busy != nil)
    }

    private func openDashboard() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
