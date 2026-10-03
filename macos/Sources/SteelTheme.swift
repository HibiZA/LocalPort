import AppKit
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

/// Steel segmented tab bar: ice-blue highlight on the selected tab.
/// `vertical` stacks the icon over the title (for the Settings window).
struct SteelTabBar<Value: Hashable>: View {
    struct Item {
        let value: Value
        let symbol: String
        let title: String
        var badge: Int?
        var shortcut: KeyEquivalent?
    }

    let items: [Item]
    @Binding var selection: Value
    var vertical = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items.indices, id: \.self) { index in
                tab(items[index])
            }
        }
        .padding(4)
        .background(SteelPanel(cornerRadius: 12))
    }

    @ViewBuilder
    private func tab(_ item: Item) -> some View {
        let button = Button {
            selection = item.value
        } label: {
            label(item, selected: selection == item.value)
        }
        .buttonStyle(.plain)
        if let shortcut = item.shortcut {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }

    private func label(_ item: Item, selected: Bool) -> some View {
        let layout = vertical
            ? AnyLayout(VStackLayout(spacing: 3))
            : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            Image(systemName: item.symbol)
                .font(.system(size: vertical ? 14 : 12, weight: .semibold))
                .frame(height: vertical ? 18 : nil)
            Text(item.title)
                .font(.system(size: vertical ? 11 : 12.5, weight: .medium))
            if let badge = item.badge, badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(Steel.amber))
            }
        }
        .foregroundStyle(selected ? Steel.ice : Steel.textSecondary)
        .shadow(color: selected ? Steel.ice.opacity(0.6) : .clear, radius: 3)
        .frame(maxWidth: .infinity, minHeight: vertical ? 44 : 30)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Steel.iceDeep.opacity(0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Steel.ice.opacity(0.5), lineWidth: 1)
                    )
            }
        }
        .contentShape(Rectangle())
    }
}

/// Hosting view that acts on the first click even when its window isn't
/// key. LocalPort is a menu bar app, so its windows are often inactive when
/// clicked; without this the first click only activates the window.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
