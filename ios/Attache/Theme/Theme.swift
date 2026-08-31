import SwiftUI

/// Design tokens for direction 1a "Signal" — see design/HANDOFF.md.
/// The app is deliberately dark-only; every color is defined here.
enum Theme {
    // MARK: Surfaces
    static let bg = Color(hex: 0x060606)
    static let raised = Color(hex: 0x101012)
    static let raisedAlt = Color(hex: 0x0C0C0E)
    static let chip = Color(hex: 0x141416)
    static let composer = Color(hex: 0x0A0A0B)
    static let codeBlock = Color.black
    static let userBubble = Color(hex: 0x1E1E22)
    static let searchField = Color(hex: 0x111113)
    static let card = Color(hex: 0x0E0E10)
    static let sheet = Color(hex: 0x141416)

    // MARK: Text
    static let text = Color(hex: 0xF4F4F2)
    static func text(_ opacity: Double) -> Color { text.opacity(opacity) }
    static let textSecondary = text.opacity(0.55)
    static let textTertiary = text.opacity(0.45)
    static let textFaint = text.opacity(0.35)

    // MARK: Accent & status
    static let accent = Color(hex: 0xFF6A2B)
    static let accentHover = Color(hex: 0xFF8551)
    static let success = Color(hex: 0x30D158)
    static let warning = Color(hex: 0xFFD60A)
    static let danger = Color(hex: 0xFF453A)
    static let diffAddText = Color(hex: 0x7CE59E)
    static let diffAddBg = success.opacity(0.10)
    static let diffDelText = Color(hex: 0xFF9C93)
    static let diffDelBg = danger.opacity(0.09)

    // MARK: Hairlines
    static let hairline = Color.white.opacity(0.08)
    static let hairlineFaint = Color.white.opacity(0.05)
    static let hairlineStrong = Color.white.opacity(0.10)
    static let accentBorder = accent.opacity(0.4)
    static let accentBorderFaint = accent.opacity(0.3)

    // MARK: Typography
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// Section header style: 10pt semibold mono, +0.12em tracking, uppercase.
    static let sectionTracking: CGFloat = 1.2

    // MARK: Metrics
    static let gutter: CGFloat = 18
    static let streamGutter: CGFloat = 16
    static let cardRadius: CGFloat = 12
    static let pinnedRadius: CGFloat = 14
    static let chipRadius: CGFloat = 7
    static let buttonRadius: CGFloat = 8
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Shared building blocks

/// The ~1.6s ease pulse used on all live dots.
struct BlinkDot: View {
    var color: Color
    var size: CGFloat = 7
    var glow: Bool = false
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: glow ? color.opacity(0.8) : .clear, radius: glow ? 4 : 0)
            .opacity(dim ? 0.25 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(Theme.mono(10, .semibold))
            .tracking(Theme.sectionTracking)
            .foregroundStyle(Theme.textFaint)
    }
}

struct ContextBar: View {
    var percent: Double // 0...100
    var height: CGFloat = 3
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(0, geo.size.width * percent / 100))
                    .animation(.easeInOut(duration: 0.6), value: percent)
            }
        }
        .frame(height: height)
    }
}

/// Back chevron matching the prototype's 10×17 stroke.
struct BackChevron: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Path { p in
                p.move(to: CGPoint(x: 8.5, y: 1.5))
                p.addLine(to: CGPoint(x: 2, y: 8.5))
                p.addLine(to: CGPoint(x: 8.5, y: 15.5))
            }
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(width: 10, height: 17)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, -6)
    }
}

/// Scale-on-press effect (~0.96) used across CTA buttons.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct TypingIndicator: View {
    @State private var phase = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.text(0.6))
                    .frame(width: 6, height: 6)
                    .offset(y: phase ? -3 : 0)
                    .opacity(phase ? 1 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                        value: phase
                    )
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .onAppear { phase = true }
    }
}
