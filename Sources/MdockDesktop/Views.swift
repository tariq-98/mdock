import SwiftUI

@main
struct MdockDesktopApp: App {
    @State private var model = Model()

    var body: some Scene {
        Window("mdock", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        MenuBarExtra {
            MenuView().environment(model)
        } label: {
            Image(systemName: model.running ? (model.status?.isGPU == true ? "cube.fill" : "shippingbox.fill") : "shippingbox")
        }
        .menuBarExtraStyle(.window)
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case overview = "Overview", gpu = "GPU", accel = "Accelerators", containers = "Containers", images = "Images", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .gpu: "cpu"
        case .accel: "bolt.horizontal.circle"
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(Model.self) private var model
    @State private var pane: Pane? = .overview

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            VStack(spacing: 0) {
                switch pane ?? .overview {
                case .overview: OverviewView()
                case .gpu: GPUView()
                case .accel: AccelView()
                case .containers: ContainersView()
                case .images: ImagesView()
                case .settings: SettingsView()
                }
                StatusBar()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                EngineBadge()
                PowerButton()
            }
        }
    }
}

struct EngineBadge: View {
    @Environment(Model.self) private var model
    var body: some View {
        if let s = model.status, s.ready {
            Label(s.isGPU ? "GPU engine" : "VZ engine", systemImage: s.isGPU ? "cube.fill" : "bolt.fill")
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(s.isGPU ? Color.purple.opacity(0.2) : Color.green.opacity(0.2), in: Capsule())
        } else {
            Label("Stopped", systemImage: "stop.circle").foregroundStyle(.secondary)
        }
    }
}

struct PowerButton: View {
    @Environment(Model.self) private var model
    var body: some View {
        if model.running {
            Button("Stop", systemImage: "stop.fill") { model.stop() }.disabled(model.busy != nil)
        } else {
            Menu {
                Button("Start with GPU (libkrun + Venus)") { model.start(gpu: true) }
                Button("Start without GPU (Virtualization.framework)") { model.start(gpu: false) }
            } label: {
                Label("Start", systemImage: "play.fill")
            } primaryAction: {
                model.start(gpu: model.configuredGPU)
            }
            .disabled(model.busy != nil)
        }
    }
}

struct StatusBar: View {
    @Environment(Model.self) private var model
    var body: some View {
        HStack {
            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy)
            } else if let message = model.message {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(2).textSelection(.enabled)
            } else if let s = model.status, s.ready {
                Text("\(model.containers.filter(\.running).count) running · \(s.ip)").foregroundStyle(.secondary)
            } else {
                Text("mdock is stopped").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: Overview

struct OverviewView: View {
    @Environment(Model.self) private var model

    var body: some View {
        ScrollView {
            if let s = model.status, s.ready {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                    Tile(title: "Engine", value: s.isGPU ? "libkrun + Venus GPU" : "Virtualization.framework",
                         detail: s.isGPU ? "Vulkan → MoltenVK → Metal" : "Rosetta for amd64, vmnet networking", icon: s.isGPU ? "cube.fill" : "bolt.fill")
                    Tile(title: "CPUs", value: "\(s.cpus) cores", detail: "all performance + efficiency cores", icon: "cpu")
                    Tile(title: "Memory", value: "\(s.balloonMiB / 1024).\(s.balloonMiB % 1024 * 10 / 1024) GiB in use",
                         detail: "of \(s.memoryGiB) GiB · guest has \(s.guestMemAvailableMiB) MiB free", icon: "memorychip")
                    Tile(title: "Boot", value: String(format: "%.1f s", s.bootSeconds), detail: "VM start to Docker ready", icon: "timer")
                    Tile(title: "Containers", value: "\(model.containers.filter(\.running).count) running",
                         detail: "\(model.containers.count) total · \(model.gpuContainers.count) using the GPU", icon: "shippingbox")
                    Tile(title: "Ports", value: s.forwards.isEmpty ? "none" : "\(s.forwards.count) forwarded",
                         detail: s.forwards.prefix(4).joined(separator: ", "), icon: "network")
                }
                .padding(20)
            } else {
                ContentUnavailableView {
                    Label("mdock is stopped", systemImage: "shippingbox")
                } description: {
                    Text("Start with the GPU engine to give containers Vulkan on the Apple GPU.")
                } actions: {
                    Button("Start with GPU") { model.start(gpu: true) }.buttonStyle(.borderedProminent)
                    Button("Start without GPU") { model.start(gpu: false) }
                }
                .padding(.top, 80)
            }
        }
    }
}

struct Tile: View {
    var title: String, value: String, detail: String, icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: GPU

struct GPUView: View {
    @Environment(Model.self) private var model
    private let usage = "docker run --device mdock.dev/gpu=all <image>"

    var body: some View {
        Form {
            Section("Apple GPU in Linux containers") {
                LabeledContent("Path", value: "Vulkan (Mesa Venus) → virtio-gpu → virglrenderer → MoltenVK → Metal")
                LabeledContent("Engine") {
                    if model.status?.isGPU == true {
                        Label("GPU engine running", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if model.running {
                        Button("Restart with GPU") { model.switchEngine(gpu: true) }
                    } else {
                        Button("Start with GPU") { model.start(gpu: true) }
                    }
                }
                LabeledContent("Use it") {
                    HStack {
                        Text(usage).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Button("Copy", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(usage, forType: .string)
                        }.labelStyle(.iconOnly)
                    }
                }
                LabeledContent("Containers using it", value: "\(model.gpuContainers.count)")
            }
            Section("Check") {
                Button("Run Vulkan check in a container") { model.checkGPU() }
                    .disabled(model.status?.isGPU != true || model.busy != nil)
                if let report = model.gpuReport {
                    Text(report).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
            Section("Notes") {
                Text("Images need Mesa's Venus driver (e.g. Fedora mesa-vulkan-drivers, Mesa 23+). Vulkan compute works for llama.cpp, ncnn, Kompute, clvk/OpenCL; CUDA and Metal APIs are not available inside Linux.")
                    .foregroundStyle(.secondary)
                Text("The GPU engine has no Rosetta: amd64 images need the VZ engine.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Accelerators

struct AccelView: View {
    @Environment(Model.self) private var model

    private let info: [String: (title: String, engine: String, usage: String)] = [
        "media": ("Media engine: remote ffmpeg", "VideoToolbox decode/encode", "--device mdock.dev/media=ffmpeg"),
        "vt": ("Media engine: VA-API", "VideoToolbox behind libva", "--device mdock.dev/media=vaapi"),
        "ml": ("Neural Engine + Apple Intelligence", "Foundation Models, CoreML, Speech", "http://ml.mdock.internal:8100"),
        "llm": ("LLMs on Metal", "llama.cpp, OpenAI API", "http://llm.mdock.internal:8200"),
        "llm-rpc": ("ggml RPC on Metal", "llama.cpp --rpc offload", "llm.mdock.internal:50052"),
    ]

    var body: some View {
        Form {
            Section("Mac accelerators available to Linux containers") {
                ForEach(model.status?.accel ?? []) { service in
                    let i = info[service.name] ?? (service.name, "", "")
                    LabeledContent {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(service.running ? "Running" : service.built ? "Starts on first use" : "Not built")
                                .foregroundStyle(service.running ? .green : service.built ? .secondary : .orange)
                            Text(i.usage).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    } label: {
                        Text(i.title)
                        Text(i.engine)
                    }
                }
                if model.status?.accel == nil {
                    Text("Start mdock to see accelerator status.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Containers

struct ContainersView: View {
    @Environment(Model.self) private var model
    @State private var selection: Container.ID?
    @State private var logs: LogsSheet?

    var body: some View {
        Table(model.containers, selection: $selection) {
            TableColumn("Name") { c in
                HStack(spacing: 6) {
                    Circle().fill(c.running ? .green : .secondary.opacity(0.4)).frame(width: 8, height: 8)
                    Text(c.name)
                    if model.gpuContainers.contains(c.Id) {
                        Text("GPU").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.purple.opacity(0.25), in: Capsule())
                    }
                }
            }
            TableColumn("Image", value: \.Image)
            TableColumn("Status", value: \.Status)
            TableColumn("Ports") { c in
                HStack {
                    ForEach(c.publishedTCP, id: \.self) { port in
                        Button(":\(port)") { model.open(port: port) }.buttonStyle(.link)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: Container.ID.self) { ids in
            if let id = ids.first, let c = model.containers.first(where: { $0.Id == id }) {
                if c.running {
                    Button("Stop") { model.container(id, "stop") }
                    Button("Restart") { model.container(id, "restart") }
                } else {
                    Button("Start") { model.container(id, "start") }
                }
                Button("Logs") { logs = LogsSheet(id: id, name: c.name) }
                Divider()
                Button("Remove", role: .destructive) { model.remove(container: id) }
            }
        } primaryAction: { ids in
            if let id = ids.first, let c = model.containers.first(where: { $0.Id == id }) { logs = LogsSheet(id: id, name: c.name) }
        }
        .overlay {
            if model.containers.isEmpty {
                ContentUnavailableView("No containers", systemImage: "shippingbox", description: Text("docker context use mdock, then docker run …"))
            }
        }
        .sheet(item: $logs) { sheet in LogsView(sheet: sheet) }
    }
}

struct LogsSheet: Identifiable {
    var id: String
    var name: String
}

struct LogsView: View {
    var sheet: LogsSheet
    @Environment(\.dismiss) private var dismiss
    @State private var text = "Loading…"

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Logs: \(sheet.name)").font(.headline)
                Spacer()
                Button("Refresh") { load() }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background.secondary)
        }
        .padding()
        .frame(width: 760, height: 480)
        .onAppear(perform: load)
    }

    private func load() {
        let id = sheet.id
        Task.detached {
            let logs = Backend.logs(id)
            await MainActor.run { text = logs.isEmpty ? "(no output)" : logs }
        }
    }
}

// MARK: Images

struct ImagesView: View {
    @Environment(Model.self) private var model
    @State private var selection: DockerImage.ID?

    var body: some View {
        Table(model.images, selection: $selection) {
            TableColumn("Image", value: \.name)
            TableColumn("Size") { i in Text(i.Size.bytes) }
            TableColumn("Created") { i in
                Text(Date(timeIntervalSince1970: TimeInterval(i.Created)), style: .relative)
            }
        }
        .contextMenu(forSelectionType: DockerImage.ID.self) { ids in
            if let id = ids.first { Button("Remove", role: .destructive) { model.remove(image: id) } }
        }
    }
}

// MARK: Settings

struct SettingsView: View {
    @Environment(Model.self) private var model
    @State private var cpus = 8.0
    @State private var memory = 8.0
    @State private var loaded = false

    private let hostCPUs = Double(ProcessInfo.processInfo.activeProcessorCount)
    private let hostGiB = Double(ProcessInfo.processInfo.physicalMemory >> 30)

    var body: some View {
        Form {
            Section("Engine") {
                Picker("Default engine", selection: Binding(
                    get: { model.configuredGPU },
                    set: { model.set("gpu", $0 ? "on" : "off") })) {
                    Text("GPU (libkrun + Venus)").tag(true)
                    Text("Virtualization.framework (Rosetta, fastest networking)").tag(false)
                }
            }
            Section("Resources (applied on next start)") {
                LabeledContent("CPUs: \(Int(cpus))") {
                    Slider(value: $cpus, in: 1...hostCPUs, step: 1, onEditingChanged: { editing in
                        if !editing { model.set("cpus", "\(Int(cpus))") }
                    })
                }
                LabeledContent("Memory: \(Int(memory)) GiB") {
                    Slider(value: $memory, in: 2...max(2, hostGiB - 2), step: 1, onEditingChanged: { editing in
                        if !editing { model.set("memory", "\(Int(memory))") }
                    })
                }
            }
            Section("Behaviour") {
                Toggle("Forward published ports to localhost", isOn: Binding(
                    get: { model.config["forwardPorts"] as? Bool ?? true },
                    set: { model.set("ports", $0 ? "on" : "off") }))
                Toggle("Return idle memory to macOS (VZ engine)", isOn: Binding(
                    get: { model.config["autoBalloon"] as? Bool ?? true },
                    set: { model.set("balloon", $0 ? "on" : "off") }))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            cpus = Double(model.config["cpus"] as? Int ?? Int(hostCPUs))
            memory = Double(model.config["memoryGiB"] as? Int ?? 8)
        }
    }
}

// MARK: Menu bar

struct MenuView: View {
    @Environment(Model.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("mdock").font(.headline)
                Spacer()
                EngineBadge()
            }
            if let s = model.status, s.ready {
                Text("\(s.cpus) CPUs · \(s.balloonMiB) MiB · \(model.containers.filter(\.running).count) running")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.containers.filter(\.running).prefix(6)) { c in
                    HStack {
                        Text(c.name).lineLimit(1)
                        if model.gpuContainers.contains(c.Id) { Image(systemName: "cube.fill").foregroundStyle(.purple) }
                        Spacer()
                        ForEach(c.publishedTCP.prefix(2), id: \.self) { p in
                            Button(":\(p)") { model.open(port: p) }.buttonStyle(.link)
                        }
                    }.font(.callout)
                }
                Divider()
                Button(s.isGPU ? "Restart without GPU" : "Restart with GPU") { model.switchEngine(gpu: !s.isGPU) }
                Button("Stop") { model.stop() }
            } else {
                Button("Start with GPU") { model.start(gpu: true) }
                Button("Start without GPU") { model.start(gpu: false) }
            }
            if let busy = model.busy {
                HStack { ProgressView().controlSize(.small); Text(busy).font(.caption) }
            }
            Divider()
            Button("Open Dashboard") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit mdock Desktop") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .padding(14)
        .frame(width: 300)
        .disabled(false)
    }
}
