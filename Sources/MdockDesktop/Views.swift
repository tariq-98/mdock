import SwiftUI

@main
struct MdockDesktopApp: App {
    @State private var model = Model()

    var body: some Scene {
        Window("mdock", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 580)
        }
        MenuBarExtra {
            MenuPanel().environment(model)
        } label: {
            Image(nsImage: MenuBarIcon.image(running: model.running))
                .accessibilityLabel(model.running ? "mdock is running" : "mdock is stopped")
        }
        .menuBarExtraStyle(.window)
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case overview, containers, images, gpu, accelerators, settings
    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .containers: "Containers"
        case .images: "Images"
        case .gpu: "GPU"
        case .accelerators: "Accelerators"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .gpu: "cpu"
        case .accelerators: "bolt.horizontal.circle"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(Model.self) private var model
    @State private var pane: Pane? = .overview

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label(p.title, systemImage: p.icon).tag(p)
            }
            .safeAreaInset(edge: .top, spacing: 0) { SidebarBrand() }
            .navigationSplitViewColumnWidth(min: 180, ideal: 196, max: 240)
        } detail: {
            detail
                .safeAreaInset(edge: .bottom, spacing: 0) { ActivityBanner() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                StateChip()
                PowerButton()
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch pane ?? .overview {
        case .overview: OverviewView { pane = $0 }
        case .containers: ContainersView()
        case .images: ImagesView()
        case .gpu: GPUView()
        case .accelerators: AccelView()
        case .settings: SettingsView()
        }
    }
}

struct SidebarBrand: View {
    @Environment(Model.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            PaperBox(ink: model.running ? 1 : 0)
                .frame(width: 26, height: 26)
                .animation(.easeInOut(duration: 0.6), value: model.running)
            Text("mdock").font(.system(size: 17, weight: .semibold).width(.expanded))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
}

struct StateChip: View {
    @Environment(Model.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            PaperBox(ink: model.running ? 1 : 0).frame(width: 15, height: 15)
            Text(chipText)
        }
        .padding(.horizontal, 6)
        .help(model.summary)
    }

    private var chipText: String {
        switch model.phase {
        case .running: model.status?.isGPU == true ? "Running on GPU engine" : "Running"
        case .stopped: "Stopped"
        case .idle: "Stopped while idle"
        case .working(let title): "\(title)…"
        }
    }
}

struct PowerButton: View {
    @Environment(Model.self) private var model

    var body: some View {
        Group {
            if model.running {
                Button("Stop", systemImage: "stop.fill") { model.stop() }
                    .help("Shut the VM down. Running containers stop.")
            } else {
                Menu {
                    Button("Start on the default engine") { model.start(gpu: false) }
                    Button("Start on the GPU engine") { model.start(gpu: true) }
                } label: {
                    Label("Start", systemImage: "play.fill")
                } primaryAction: {
                    model.start(gpu: model.configuredGPU)
                }
                .help("Start mdock")
            }
        }
        .disabled(model.busy != nil)
    }
}

/// What mdock is doing, or what went wrong, along the bottom of the window. Hidden otherwise.
struct ActivityBanner: View {
    @Environment(Model.self) private var model

    var body: some View {
        if let busy = model.busy {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(busy)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.bar)
        } else if let message = model.message {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    model.message = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }
}

// MARK: Overview

struct OverviewView: View {
    @Environment(Model.self) private var model
    var select: (Pane) -> Void

    var body: some View {
        PaneScroll {
            Hero()
            if let s = model.status, s.ready {
                Facts(status: s)
                RunningNow(select: select)
                HowItRuns(status: s, select: select)
            }
        }
    }
}

struct Hero: View {
    @Environment(Model.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 30) {
            BoxIllustration(phase: model.phase)
                .frame(width: 140, height: 140)
            VStack(alignment: .leading, spacing: 8) {
                Text(model.phase.title)
                    .font(.system(size: 38, weight: .semibold).width(.expanded))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: model.phase)
                Text(model.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HeroActions().padding(.top, 10)
            }
            .frame(maxWidth: 470, alignment: .leading)
        }
        .padding(.vertical, 6)
    }
}

struct HeroActions: View {
    @Environment(Model.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .running:
                let gpu = model.status?.isGPU == true
                Button("Stop", systemImage: "stop.fill") { model.stop() }
                    .secondaryAction()
                Button(gpu ? "Switch to default engine" : "Switch to GPU engine") { model.switchEngine(gpu: !gpu) }
                    .secondaryAction()
                    .help("Restarts the VM on the other engine. Running containers stop first.")
            case .stopped, .idle:
                Button("Start", systemImage: "play.fill") { model.start(gpu: model.configuredGPU) }
                    .primaryAction()
                Button(model.configuredGPU ? "Start on default engine" : "Start with GPU") { model.start(gpu: !model.configuredGPU) }
                    .secondaryAction()
            case .working:
                EmptyView()
            }
        }
        .controlSize(.large)
        .disabled(model.busy != nil)
    }
}

struct Facts: View {
    @Environment(Model.self) private var model
    var status: DaemonStatus

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Fact("Cores") { Text(String(status.cpus)) }
            Divider()
            if let memory = model.memory {
                Fact("Memory used") {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(String(format: "%.1f GiB", memory.used))
                        MemoryBar(used: memory.used, held: memory.held, total: memory.total)
                        Text(String(format: "of %d GiB. The VM holds %.1f GiB now.", Int(memory.total), memory.held))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 230)
                Divider()
            }
            Fact("Boot time") { Text(String(format: "%.1f s", status.bootSeconds)) }
            Divider()
            Fact("Idle stop") {
                if let idle = status.idleStop, idle.enabled {
                    Text("\(idle.minutes) min")
                } else {
                    Text("Off")
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 16)
        .background(Surface())
    }
}

struct Fact<Content: View>: View {
    var label: String
    var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            content
                .font(.system(size: 22, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RunningNow: View {
    @Environment(Model.self) private var model
    var select: (Pane) -> Void
    @State private var logs: LogsSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Running now") {
                if !model.containers.isEmpty {
                    Button("All containers") { select(.containers) }.buttonStyle(.link)
                }
            }
            let running = model.runningContainers
            if running.isEmpty {
                Text("No containers are running. Start one with docker run, or from Containers.")
                    .foregroundStyle(.secondary)
            } else {
                ContainerList(containers: running) { logs = LogsSheet(id: $0.Id, name: $0.name) }
            }
        }
        .sheet(item: $logs) { LogsView(sheet: $0) }
    }
}

struct HowItRuns: View {
    @Environment(Model.self) private var model
    var status: DaemonStatus
    var select: (Pane) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("How it runs")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 28, verticalSpacing: 11) {
                Detail("Engine", status.isGPU ? "GPU engine: libkrun with a Venus GPU" : "Default engine: Apple Virtualization")
                if let amd64 = status.x86?["amd64"] {
                    Detail("x86-64 programs", translator(amd64))
                }
                if let i386 = status.x86?["386"] {
                    Detail("32-bit x86 programs", translator(i386))
                }
                if let tso = status.tso {
                    Detail("x86 memory order", tso ? "Kept by the CPU (hardware TSO)" : "Kept by the translator in software")
                }
                if let kernel = status.kernel, !kernel.isEmpty {
                    Detail("Linux kernel", kernel)
                }
                Detail("VM address", status.ip)
                Detail("Kubernetes", kubernetes)
                GridRow {
                    Text("Accelerators").foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Text(accelerators)
                        Button("Show") { select(.accelerators) }.buttonStyle(.link)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface())
        }
    }

    private func translator(_ id: String) -> String {
        ["rosetta": "Rosetta", "fex": "FEX", "qemu": "QEMU"][id] ?? id
    }

    private var kubernetes: String {
        guard let k8s = status.kubernetes else { return "Off" }
        switch k8s.state {
        case "off": return "Off"
        case "up": return "Running" + ((k8s.version ?? "").isEmpty ? "" : ", " + (k8s.version ?? ""))
        default: return k8s.state.prefix(1).uppercased() + k8s.state.dropFirst()
        }
    }

    private var accelerators: String {
        let services = status.accel ?? []
        let running = services.filter(\.running).count
        let waiting = services.filter { $0.built && !$0.running }.count
        if services.isEmpty { return "None" }
        if waiting == 0 { return "\(running) running" }
        return "\(running) running, \(waiting) start when first used"
    }
}

struct Detail: View {
    var label: String
    var value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

// MARK: Containers

struct ContainersView: View {
    @Environment(Model.self) private var model
    @State private var onlyRunning = false
    @State private var logs: LogsSheet?

    var body: some View {
        PaneScroll {
            PaneHeader("Containers", subtitle: subtitle) {
                Picker("Show", selection: $onlyRunning) {
                    Text("All").tag(false)
                    Text("Running").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            let list = onlyRunning ? model.runningContainers : model.containers
            if !model.running {
                Text("Start mdock to see its containers.").foregroundStyle(.secondary)
            } else if list.isEmpty {
                Text(onlyRunning ? "No containers are running." : "No containers yet. Create one with docker run.")
                    .foregroundStyle(.secondary)
            } else {
                ContainerList(containers: list) { logs = LogsSheet(id: $0.Id, name: $0.name) }
            }
        }
        .sheet(item: $logs) { LogsView(sheet: $0) }
    }

    private var subtitle: String? {
        guard model.running else { return nil }
        let running = model.runningContainers.count, total = model.containers.count
        return "\(running) running, \(total) in all. Double-click one to see its logs."
    }
}

struct ContainerList: View {
    var containers: [Container]
    var onLogs: (Container) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(containers) { container in
                ContainerRow(container: container, onLogs: onLogs)
                if container.id != containers.last?.id {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .background(Surface())
    }
}

struct ContainerRow: View {
    @Environment(Model.self) private var model
    var container: Container
    var onLogs: (Container) -> Void
    @State private var confirmRemove = false

    var body: some View {
        HStack(spacing: 14) {
            PaperBox(ink: container.running ? 1 : 0)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(container.name).fontWeight(.semibold).lineLimit(1)
                    if model.gpuContainers.contains(container.Id) { Tag("GPU") }
                }
                Text(container.Image)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 16)
            Text(container.Status)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ForEach(container.publishedTCP.prefix(2), id: \.self) { port in
                let address = "localhost:" + String(port)
                Button(address) { model.open(port: port) }
                    .buttonStyle(.link)
                    .font(.system(.callout, design: .monospaced))
                    .help("Open http://" + address)
            }
            Button {
                model.container(container.Id, container.running ? "stop" : "start")
            } label: {
                Image(systemName: container.running ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .help(container.running ? "Stop" : "Start")
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onLogs(container) }
        .contextMenu { actions }
        .disabled(model.busy != nil)
        .confirmationDialog("Remove \(container.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.remove(container: container.Id) }
        } message: {
            Text("The container and the changes it made to its files are deleted. Volumes are kept.")
        }
    }

    @ViewBuilder private var actions: some View {
        if container.running {
            Button("Stop") { model.container(container.Id, "stop") }
            Button("Restart") { model.container(container.Id, "restart") }
        } else {
            Button("Start") { model.container(container.Id, "start") }
        }
        Button("Show logs") { onLogs(container) }
        Divider()
        Button("Remove…", role: .destructive) { confirmRemove = true }
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(sheet.name).font(.system(size: 20, weight: .semibold).width(.expanded))
                Text("Last 1000 lines").foregroundStyle(.secondary)
                Spacer()
                Button("Reload") { load() }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(Surface())
        }
        .padding(20)
        .frame(width: 780, height: 500)
        .onAppear(perform: load)
    }

    private func load() {
        let id = sheet.id
        Task.detached {
            let logs = Backend.logs(id)
            await MainActor.run { text = logs.isEmpty ? "This container hasn't written any output." : logs }
        }
    }
}

// MARK: Images

struct ImagesView: View {
    @Environment(Model.self) private var model

    var body: some View {
        PaneScroll {
            PaneHeader("Images", subtitle: subtitle)
            if !model.running {
                Text("Start mdock to see its images.").foregroundStyle(.secondary)
            } else if model.images.isEmpty {
                Text("No images yet. Pull one with docker pull, or build one with docker build.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.images) { image in
                        ImageRow(image: image)
                        if image.id != model.images.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(Surface())
            }
        }
    }

    private var subtitle: String? {
        guard model.running, !model.images.isEmpty else { return nil }
        let total = model.images.reduce(Int64(0)) { $0 + $1.Size }
        let count = model.images.count == 1 ? "1 image" : "\(model.images.count) images"
        return "\(count), \(total.bytes) on disk."
    }
}

struct ImageRow: View {
    @Environment(Model.self) private var model
    var image: DockerImage

    var body: some View {
        HStack(spacing: 14) {
            Text(image.name)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 16)
            Text(image.Size.bytes).foregroundStyle(.secondary).monospacedDigit()
            Text(Date(timeIntervalSince1970: TimeInterval(image.Created)), style: .relative)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            Button {
                model.remove(image: image.Id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this image")
            .disabled(model.busy != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: GPU

struct GPUView: View {
    @Environment(Model.self) private var model
    private let usage = "docker run --device mdock.dev/gpu=all <image>"

    var body: some View {
        let onGPU = model.status?.isGPU == true && model.running
        PaneScroll {
            PaneHeader("GPU", subtitle: "Containers can use the Mac's GPU through Vulkan, OpenGL and OpenCL when mdock runs on the GPU engine.")
            HStack(spacing: 16) {
                PaperBox(ink: onGPU ? 1 : 0).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(onGPU ? "The GPU engine is running" : "The GPU engine is off").font(.headline)
                    Text(onGPU ? "Give a container the GPU with the device below."
                               : "Switching engines restarts the VM, so running containers stop first.")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !onGPU {
                    Button(model.running ? "Switch to GPU engine" : "Start with GPU") {
                        model.running ? model.switchEngine(gpu: true) : model.start(gpu: true)
                    }
                    .primaryAction()
                    .disabled(model.busy != nil)
                }
            }
            .padding(18)
            .background(Surface())
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Give a container the GPU")
                CodeToken(text: usage)
                Text("The image needs Mesa's Venus Vulkan driver, such as Fedora's or Debian's mesa-vulkan-drivers. For OpenGL, add -e GALLIUM_DRIVER=zink. CUDA and Metal aren't available inside Linux.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Check what containers see") {
                    Button("Run check") { model.checkGPU() }
                        .disabled(!onGPU || model.busy != nil)
                }
                if let report = model.gpuReport {
                    ScrollView(.horizontal) {
                        Text(report)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(14)
                    }
                    .background(Surface())
                } else {
                    Text("Runs a small container that lists the Vulkan, OpenGL and OpenCL devices it finds.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Accelerators

struct AccelView: View {
    @Environment(Model.self) private var model

    private let info: [String: (title: String, detail: String, usage: String, icon: String)] = [
        "media": ("Video engine for ffmpeg", "ffmpeg and ffprobe in the container run on the Mac's media engine.",
                  "--device mdock.dev/media=ffmpeg", "film"),
        "vt": ("Video engine for VA-API", "Hardware video decoding and encoding through standard VA-API.",
               "--device mdock.dev/media=vaapi", "film.stack"),
        "ml": ("Neural Engine and Apple Intelligence", "Core ML models, speech to text and on-device chat.",
               "http://ml.mdock.internal:8100", "brain"),
        "llm": ("LLMs on Metal", "OpenAI- and Ollama-compatible APIs on llama.cpp.",
                "http://llm.mdock.internal:8200", "text.bubble"),
        "llm-rpc": ("llama.cpp RPC on Metal", "Offload model layers to the Mac's GPU with llama.cpp's --rpc.",
                    "llm.mdock.internal:50052", "point.3.connected.trianglepath.dotted"),
    ]

    var body: some View {
        PaneScroll {
            PaneHeader("Accelerators", subtitle: "The Mac's media engine, Neural Engine and GPU, for any container. Each one starts when a container first uses it.")
            if let services = model.status?.accel, !services.isEmpty {
                VStack(spacing: 0) {
                    ForEach(services) { service in
                        row(service)
                        if service.id != services.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Surface())
                Text("These run on the Mac as you, and every container can reach them. Only give the media devices to containers you trust.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Start mdock to see the accelerators.").foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ service: AccelService) -> some View {
        let i = info[service.name] ?? (service.name, "", "", "bolt")
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: i.icon)
                .font(.title2)
                .foregroundStyle(service.running ? Paper.fold : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(i.title).fontWeight(.semibold)
                    Text(service.running ? "Running" : service.built ? "Starts when first used" : "Not built")
                        .font(.callout)
                        .foregroundStyle(service.built ? Color.secondary : Color.orange)
                }
                Text(i.detail).foregroundStyle(.secondary)
                if !i.usage.isEmpty {
                    CodeToken(text: i.usage).padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
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
    private let idleChoices = [0, 5, 10, 15, 30, 60]

    var body: some View {
        // One scrolling form: a header outside it made the pane taller than the window.
        Form {
                Section {
                    Picker("Start on", selection: Binding(
                        get: { model.configuredGPU },
                        set: { model.set("gpu", $0 ? "on" : "off") })) {
                        Text("Default engine").tag(false)
                        Text("GPU engine").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Text(model.configuredGPU
                         ? "The Mac's GPU for containers, and memory goes back to macOS within seconds. x86 images run through FEX."
                         : "Apple Virtualization: the fastest networking, and x86 images run through Rosetta.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } header: {
                    VStack(alignment: .leading, spacing: 22) {
                        PaneHeader("Settings", subtitle: "Engine and resource changes apply the next time mdock starts.")
                            .foregroundStyle(.primary)
                        Text("Engine")
                    }
                    .padding(.top, 8)
                }
                Section("Resources") {
                    LabeledContent {
                        Slider(value: $cpus, in: 1...hostCPUs, step: 1) { editing in
                            if !editing { model.set("cpus", String(Int(cpus))) }
                        }
                    } label: {
                        Text("Cores")
                        Text("\(Int(cpus)) of \(Int(hostCPUs))").monospacedDigit()
                    }
                    LabeledContent {
                        Slider(value: $memory, in: 2...max(2, hostGiB - 2), step: 1) { editing in
                            if !editing { model.set("memory", String(Int(memory))) }
                        }
                    } label: {
                        Text("Memory")
                        Text("\(Int(memory)) GiB").monospacedDigit()
                    }
                }
                Section("When idle") {
                    Picker("Stop the VM", selection: Binding(
                        get: { model.idleMinutes },
                        set: { model.set("idle", String($0)) })) {
                        ForEach(idleChoices, id: \.self) { minutes in
                            Text(minutes == 0 ? "Never" : "After \(minutes) minutes").tag(minutes)
                        }
                    }
                    Text("With nothing running and no docker commands. The next docker command starts it again. Needs mdock autostart on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("Behaviour") {
                    Toggle("Make published ports available on localhost", isOn: Binding(
                        get: { model.config["forwardPorts"] as? Bool ?? true },
                        set: { model.set("ports", $0 ? "on" : "off") }))
                    Toggle("Give unused memory back to macOS (default engine)", isOn: Binding(
                        get: { model.config["autoBalloon"] as? Bool ?? true },
                        set: { model.set("balloon", $0 ? "on" : "off") }))
                }
            }
            .formStyle(.grouped)
            .disabled(model.busy != nil)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            cpus = Double(model.config["cpus"] as? Int ?? Int(hostCPUs))
            memory = Double(model.config["memoryGiB"] as? Int ?? 8)
        }
    }
}
