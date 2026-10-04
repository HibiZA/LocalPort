import AppKit
import SwiftUI

/// LocalPort's look, after the app icon: dark liquid steel with icy blue
/// accents. Surfaces are brushed-metal gradients with a soft edge, lighter
/// at the top; no chrome highlights or glows.
enum Steel {
    /// Accent: running servers, the selected tab, hover.
    static let ice = Color(hex: 0x7FD8FF)
    static let iceDeep = Color(hex: 0x1A6FD0)
    /// Waiting states and unclaimed ports.
    static let amber = Color(hex: 0xF0AE62)
    static let danger = Color(hex: 0xFF6B6B)

    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color(hex: 0xA4ACB9)
    static let textTertiary = Color(hex: 0x6B7280)

    /// Window and popover background.
    static let background = LinearGradient(
        colors: [Color(hex: 0x17191E), Color(hex: 0x0D0E11), Color(hex: 0x08090B)],
        startPoint: .top, endPoint: .bottom
    )

    /// Raised steel: cards, buttons, tiles.
    static let surface = LinearGradient(
        colors: [Color(hex: 0x1D2026), Color(hex: 0x14161A)],
        startPoint: .top, endPoint: .bottom
    )

    /// Soft edge of a steel surface, catching a little light at the top.
    static let edge = LinearGradient(
        colors: [Color.white.opacity(0.12), Color.white.opacity(0.04)],
        startPoint: .top, endPoint: .bottom
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

/// A steel surface with a soft edge.
struct SteelPanel: View {
    var cornerRadius: CGFloat = 12
    var highlighted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(Steel.surface)
            .overlay(shape.fill(Color.white.opacity(highlighted ? 0.04 : 0)))
            .overlay(shape.strokeBorder(Steel.edge, lineWidth: 1))
    }
}

/// Segmented tab bar; the selected tab is tinted ice blue.
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
        .padding(3)
        .background(SteelPanel(cornerRadius: 10))
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
                .font(.system(size: vertical ? 14 : 12, weight: .medium))
                .frame(height: vertical ? 18 : nil)
            Text(item.title)
                .font(.system(size: vertical ? 11 : 12.5, weight: .medium))
            if let badge = item.badge, badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Steel.amber)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(Steel.amber.opacity(0.16)))
            }
        }
        .foregroundStyle(selected ? Steel.ice : Steel.textSecondary)
        .frame(maxWidth: .infinity, minHeight: vertical ? 44 : 28)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Steel.iceDeep.opacity(0.20))
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
