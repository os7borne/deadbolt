import SwiftUI

/// "Graphite & Brass" — tokens from the design canvas (https://claude.ai/artifact/XaS4NKFZCvWkKNTgoifMDJ).
enum DB {
    static let ground   = Color(hex: 0x0B0C0F)
    static let raised   = Color(hex: 0x111216)   // sheets, popovers
    static let surface  = Color(hex: 0x15171C)   // cards
    static let control  = Color(hex: 0x1F2229)   // icon buttons, selected rows
    static let line     = Color(hex: 0x22252D)
    static let lineStrong = Color(hex: 0x2B2E36)
    static let text     = Color(hex: 0xF2F0EA)
    static let text2    = Color(hex: 0xA3A7B0)
    static let text3    = Color(hex: 0x8A8F99)
    static let brass    = Color(hex: 0xD4AF6A)
    static let onBrass  = Color(hex: 0x1A1408)
    static let brassWash = Color(hex: 0x2B2414)
    static let good     = Color(hex: 0x6FCF97)
    static let goodWash = Color(hex: 0x15301F)
    static let danger   = Color(hex: 0xFF8C7E)
    static let dangerWash = Color(hex: 0x1C1413)

    static let projectURL = URL(string: "https://deadbolt.osborne.vc")!

    /// A stable tile colour per site, so a site always looks the same everywhere.
    static func tile(for key: String) -> Color {
        let palette: [UInt32] = [0x2A2F3A, 0x3A2A1E, 0x263238, 0x1E2B3A, 0x2E2E2E, 0x2A2540, 0x1E3A30, 0x3A1E2A]
        let sum = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return Color(hex: palette[sum % palette.count])
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

extension Font {
    static func db(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func dbMono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

// MARK: reusable pieces

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(DB.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(DB.line))
    }
}

struct CardDivider: View {
    var body: some View { Rectangle().fill(DB.line).frame(height: 1) }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.db(13, .semibold)).tracking(0.8).foregroundStyle(DB.text3)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 4)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 56
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.db(17, .semibold)).foregroundStyle(DB.onBrass)
            .frame(maxWidth: .infinity).frame(height: height)
            .background(DB.brass.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 50
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.db(16)).foregroundStyle(DB.text)
            .frame(maxWidth: .infinity).frame(height: height)
            .background(configuration.isPressed ? DB.control : .clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DB.lineStrong))
    }
}

/// 44×44 icon button (copy, reveal…). Always has an accessibility label.
/// A button whose label shows a checkmark for a moment after it is used: the confirmation for copy actions, in place
/// of a toast. `label` is given whether the checkmark is showing.
struct TickButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: (Bool) -> Label
    @State private var done = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Button {
            action()
            reset?.cancel()
            withAnimation(.snappy(duration: 0.2)) { done = true }
            reset = Task {
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { withAnimation(.snappy(duration: 0.2)) { done = false } }
            }
        } label: { label(done) }
        .accessibilityValue(done ? "Copied" : "")
    }
}

extension Image {
    /// An icon that turns into a checkmark while `done`.
    static func tick(_ name: String, done: Bool) -> some View {
        Image(systemName: done ? "checkmark" : name).contentTransition(.symbolEffect(.replace))
    }
}

struct IconButton: View {
    let systemName: String
    let label: String
    var prominent = false
    let action: () -> Void

    /// The copy icon confirms itself with a checkmark; other icons (show/hide…) don't.
    private var isCopy: Bool { systemName == "doc.on.doc" }

    var body: some View {
        Group {
            if isCopy { TickButton(action: action) { face($0) } } else { Button(action: action) { face(false) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func face(_ done: Bool) -> some View {
        Image.tick(systemName, done: done).font(.system(size: 14, weight: .semibold))
            .foregroundStyle(done ? DB.good : (prominent ? DB.onBrass : DB.text))
            .frame(width: 38, height: 38)
            .background(done ? DB.goodWash : (prominent ? DB.brass : DB.control), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The site's icon (through Deadbolt's relay) on a light tile, or its first letter while loading / if there's none.
struct SiteTile: View {
    let title: String
    var site: String? = nil
    var size: CGFloat = 42
    @State private var store = IconStore.shared

    var body: some View {
        Group {
            if let site, IconStore.enabled, let img = store.image(for: site) {
                Image(platformImage: img).resizable().interpolation(.high).scaledToFit()
                    .padding(size * 0.14)
                    .frame(width: size, height: size)
                    .background(Color(hex: 0xF2F0EA), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            } else {
                Text(String(title.prefix(1)).uppercased())
                    .font(.db(size * 0.4, .bold)).foregroundStyle(DB.text)
                    .frame(width: size, height: size)
                    .background(DB.tile(for: title), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            }
        }
        .accessibilityHidden(true)
        .task(id: site) { if let site { await store.load(site) } }
    }
}

/// Just the padlock-and-shield from the logo, filled with the logo's gold (no tile). For headers on dark surfaces.
struct DeadboltGlyph: View {
    var height: CGFloat = 20
    static let gold = LinearGradient(colors: [Color(hex: 0xFFD84A), Color(hex: 0xC88A12)], startPoint: .topLeading, endPoint: .bottomTrailing)
    var body: some View {
        Image("LockGlyph").renderingMode(.template).resizable().interpolation(.high).scaledToFit()
            .frame(height: height)
            .foregroundStyle(Self.gold)
            .accessibilityHidden(true)
    }
}

/// The Deadbolt logo (Assets › Logo), clipped to the app-icon shape.
struct DeadboltMark: View {
    var size: CGFloat = 54
    var body: some View {
        Image("Logo")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .shadow(color: .black.opacity(size > 40 ? 0.35 : 0), radius: size * 0.12, y: size * 0.06)
            .accessibilityHidden(true)
    }
}
