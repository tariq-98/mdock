import AppKit
import SwiftUI

/// mdock's paper colors, taken from the app icon: a red origami box with a blush inside.
enum Paper {
    /// The box's outer red (#DF4D3A in the icon); also the tint of primary actions.
    static let fold = Color(red: 0.875, green: 0.302, blue: 0.227)
    /// A deeper red for text on blush.
    static let crease = Color(red: 0.690, green: 0.200, blue: 0.157)
    /// The inside of the box (#F3D0CC).
    static let blush = Color(red: 0.953, green: 0.816, blue: 0.800)
}

/// The box artwork (desktop/Box.png): from the app's resources, or the repository in development.
@MainActor
enum BoxArt {
    static let image: NSImage? = {
        if let url = Bundle.main.url(forResource: "Box", withExtension: "png"), let image = NSImage(contentsOf: url) {
            return image
        }
        var dir = URL(fileURLWithPath: Bundle.main.executablePath ?? "").deletingLastPathComponent()
        while dir.path != "/" {
            if let image = NSImage(contentsOf: dir.appendingPathComponent("desktop/Box.png")) { return image }
            dir.deleteLastPathComponent()
        }
        return nil
    }()
}

/// The paper box from the artwork. `ink` colors it (1 red paper, 0 grey: stopped); `lift` and
/// `tilt` move it, for the transitions.
struct PaperBox: View {
    var lift: Double = 1
    var ink: Double = 1
    var tilt: Double = 0

    var body: some View {
        Group {
            if let art = BoxArt.image {
                Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "shippingbox.fill").resizable().aspectRatio(contentMode: .fit).foregroundStyle(Paper.fold)
            }
        }
        .saturation(ink)
        .opacity(0.45 + 0.55 * ink)
        .scaleEffect(0.86 + 0.14 * lift, anchor: .bottom)
        .rotationEffect(.degrees(tilt), anchor: .bottom)
        .accessibilityHidden(true)
    }
}

/// The box for the current state: red and upright while mdock runs, grey and settled when it's
/// stopped, rocking while a start or stop is under way.
struct BoxIllustration: View {
    var phase: Model.Phase
    var shadowRadius: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lift = 0.45
    @State private var ink = 0.0
    @State private var tilt = 0.0

    var body: some View {
        PaperBox(lift: lift, ink: ink, tilt: tilt)
            .shadow(color: .black.opacity(0.08 + 0.16 * ink), radius: shadowRadius, y: shadowRadius * 0.6)
            .task(id: phase) { await follow(phase) }
    }

    private func follow(_ phase: Model.Phase) async {
        switch phase {
        case .running:
            settle(lift: 1, ink: 1)
        case .stopped, .idle:
            settle(lift: 0.45, ink: 0)
        case .working:
            if reduceMotion {
                lift = 0.8
                ink = 0.6
                tilt = 0
                return
            }
            withAnimation(.easeInOut(duration: 0.6)) { ink = 0.6 }
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.8)) {
                    lift = 0.75
                    tilt = -5
                }
                try? await Task.sleep(for: .milliseconds(800))
                if Task.isCancelled { break }
                withAnimation(.easeInOut(duration: 0.8)) {
                    lift = 1
                    tilt = 3
                }
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
    }

    private func settle(lift: Double, ink: Double) {
        let change = {
            self.lift = lift
            self.ink = ink
            self.tilt = 0
        }
        if reduceMotion {
            change()
        } else {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7), change)
        }
    }
}

/// The menu bar glyph: the artwork as a template image, its red walls solid ink and its blush
/// inside faint. Full strength while mdock runs, dimmed while it's stopped.
@MainActor
enum MenuBarIcon {
    static let open = make(strength: 1)
    static let closed = make(strength: 0.45)

    static func image(running: Bool) -> NSImage { running ? open : closed }

    private static func make(strength: CGFloat) -> NSImage {
        guard let art = BoxArt.image else {
            let symbol = NSImage(systemSymbolName: strength == 1 ? "shippingbox.fill" : "shippingbox", accessibilityDescription: "mdock") ?? NSImage()
            symbol.isTemplate = true
            return symbol
        }
        let size = NSSize(width: (16 * art.size.width / art.size.height).rounded(), height: 16)
        let image = NSImage(size: size)
        for scale in [1.0, 2.0, 3.0] as [CGFloat] {
            let width = Int(size.width * scale), height = Int(size.height * scale)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0),
                  let data = rep.bitmapData else { continue }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            art.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            // Paper to ink: template images only keep alpha, so dark red becomes solid and blush faint.
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * rep.bytesPerRow + x * 4
                    let alpha = CGFloat(data[i + 3]) / 255
                    guard alpha > 0 else { continue }
                    let luminance = (0.299 * CGFloat(data[i]) + 0.587 * CGFloat(data[i + 1]) + 0.114 * CGFloat(data[i + 2])) / 255 / alpha
                    let ink = min(1, max(0.28, 1 - (luminance - 0.45) * 1.5)) * alpha * strength
                    data[i] = 0
                    data[i + 1] = 0
                    data[i + 2] = 0
                    data[i + 3] = UInt8((ink * 255).rounded())
                }
            }
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        image.accessibilityDescription = "mdock"
        return image
    }
}

// MARK: Building blocks

/// A quiet grouped surface for lists and facts.
struct Surface: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .quaternarySystemFill))
    }
}

struct PaneHeader<Accessory: View>: View {
    var title: String
    var subtitle: String?
    var accessory: Accessory

    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 26, weight: .semibold).width(.expanded))
                if let subtitle {
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
    }
}

extension PaneHeader where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

struct SectionTitle<Accessory: View>: View {
    var title: String
    var accessory: Accessory

    init(_ title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 15, weight: .semibold).width(.expanded))
            Spacer(minLength: 0)
            accessory
        }
    }
}

extension SectionTitle where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// A scrolling pane with mdock's margins and a readable maximum width.
struct PaneScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) { content }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Something you'd type: shown in monospace, with a copy button.
struct CodeToken: View {
    var text: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .help(copied ? "Copied" : "Copy")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct Tag: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Paper.crease)
            .background(Paper.blush.opacity(0.75), in: Capsule())
    }
}

/// Memory as paper in a tray: what Linux uses (red), what the VM holds right now (blush), and the
/// most it can grow to (the track).
struct MemoryBar: View {
    var used: Double
    var held: Double
    var total: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let scale = total > 0 ? width / total : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Paper.blush.opacity(0.85)).frame(width: max(6, held * scale))
                Capsule().fill(Paper.fold).frame(width: max(6, used * scale))
            }
        }
        .frame(height: 7)
        .animation(.easeInOut(duration: 0.6), value: used)
        .animation(.easeInOut(duration: 0.6), value: held)
    }
}

extension View {
    /// The one prominent action in a place: Liquid Glass on macOS 26, tinted with the box's red.
    @ViewBuilder func primaryAction() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent).tint(Paper.fold)
        } else {
            buttonStyle(.borderedProminent).tint(Paper.fold)
        }
    }

    @ViewBuilder func secondaryAction() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// Rows in the menu bar panel that highlight under the pointer, like menu items.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovering && isEnabled ? (configuration.isPressed ? 0.16 : 0.09) : 0))
                )
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

struct MenuLabel: View {
    var title: String
    var systemImage: String?

    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage ?? "circle")
                .opacity(systemImage == nil ? 0 : 1)
                .frame(width: 16)
            Text(title)
            Spacer(minLength: 0)
        }
    }
}
