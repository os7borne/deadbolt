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
struct IconButton: View {
    let systemName: String
    let label: String
    var prominent = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(prominent ? DB.onBrass : DB.text)
                .frame(width: 44, height: 44)
                .background(prominent ? DB.brass : DB.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct SiteTile: View {
    let title: String
    var size: CGFloat = 42
    var body: some View {
        Text(String(title.prefix(1)).uppercased())
            .font(.db(size * 0.4, .bold)).foregroundStyle(DB.text)
            .frame(width: size, height: size)
            .background(DB.tile(for: title), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
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
