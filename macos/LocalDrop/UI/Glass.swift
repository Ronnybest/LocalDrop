import SwiftUI

/// Liquid Glass on macOS 26+, the closest material look before it.
extension View {
    /// A floating card: glass on macOS 26+, a quiet fill before.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 14, tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            glassEffect(tint.map { Glass.regular.tint($0.opacity(0.25)) } ?? .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background((tint ?? .primary).opacity(0.08), in: .rect(cornerRadius: cornerRadius))
        }
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }
}

/// Groups glass shapes so they blend and morph together (macOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A device or state glyph in a tinted circle.
struct IconBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: Circle())
    }
}

/// The background of a floating panel: Liquid Glass over whatever is behind the window on
/// macOS 26+, the HUD-style blur before. The panel window itself is transparent.
struct PanelGlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.masksToBounds = true
        return blur
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

extension View {
    /// Content of a floating panel: padded, on a glass card that fills the transparent window.
    func panelCard(width: CGFloat, cornerRadius: CGFloat = 26) -> some View {
        frame(width: width, alignment: .leading)
            .background(PanelGlassBackground(cornerRadius: cornerRadius))
            .clipShape(.rect(cornerRadius: cornerRadius))
    }
}

/// A small round icon button (close, decline), glass on macOS 26+.
struct CircleButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .circleGlass()
        .help(help)
        .accessibilityLabel(help)
    }
}

private extension View {
    @ViewBuilder
    func circleGlass() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.interactive(), in: .circle)
        } else {
            background(.primary.opacity(0.08), in: Circle())
        }
    }
}
