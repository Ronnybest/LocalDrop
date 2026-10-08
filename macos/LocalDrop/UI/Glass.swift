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
