import SwiftUI

/// LocalPort's look, matching the app icon: near-black liquid steel with
/// sharp chrome edges and ice-blue accents.
enum Steel {
    static let ice = Color(hex: 0x7FD8FF)
    static let iceDeep = Color(hex: 0x1A6FD0)
    /// Warm glint, as on the icon's chrome rim; used for unclaimed ports.
    static let amber = Color(hex: 0xFFB45C)
    static let danger = Color(hex: 0xFF6B6B)

    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color(hex: 0xA4ACB9)
    static let textTertiary = Color(hex: 0x6B7280)

    /// Popover / window background.
    static let background = LinearGradient(
        colors: [Color(hex: 0x17191E), Color(hex: 0x0B0C0F), Color(hex: 0x060709)],
        startPoint: .top, endPoint: .bottom
    )

    /// Raised steel surface (cards, buttons, badges).
    static let surface = LinearGradient(
        colors: [Color(hex: 0x1D2026), Color(hex: 0x121419)],
        startPoint: .top, endPoint: .bottom
    )

    /// Chrome edge: mostly dim with a few hard highlights, like polished metal.
    static let chrome = AngularGradient(
        stops: [
            .init(color: .white.opacity(0.10), location: 0.00),
            .init(color: .white.opacity(0.55), location: 0.08),
            .init(color: .white.opacity(0.08), location: 0.18),
            .init(color: .white.opacity(0.04), location: 0.40),
            .init(color: Color(hex: 0x9FD9FF).opacity(0.45), location: 0.55),
            .init(color: .white.opacity(0.05), location: 0.64),
            .init(color: .white.opacity(0.04), location: 0.82),
            .init(color: .white.opacity(0.40), location: 0.92),
            .init(color: .white.opacity(0.10), location: 1.00),
        ],
        center: .center,
        angle: .degrees(-35)
    )
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// A steel surface with a chrome edge.
struct SteelPanel: View {
    var cornerRadius: CGFloat = 14
    var highlighted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(Steel.surface)
            .overlay(shape.fill(Color.white.opacity(highlighted ? 0.04 : 0)))
            .overlay(shape.strokeBorder(Steel.chrome, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
    }
}
