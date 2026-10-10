import AppKit

/// The menu bar drop in each state. Every state is drawn the same way so the icon never
/// changes size.
@MainActor
enum MenuBarIcon {
    /// Template images are tinted by the system (light/dark menu bar); the visible state keeps its green.
    private static func menuIcon(_ symbol: String, color: NSColor? = nil) -> NSImage {
        var config = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        if let color { config = config.applying(.init(hierarchicalColor: color)) }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Dewlet")?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = color == nil
        return image
    }

    private static let idleIcon = menuIcon("drop.halffull")
    private static let visibleIcon = menuIcon("drop.halffull", color: .systemGreen)

    /// While receiving, the drop fills from the bottom with the progress, in 5% steps: smooth to
    /// the eye without redrawing the menu bar on every progress update.
    private static let progressSteps = 20
    private static let progressIcons: [NSImage] = {
        let outline = menuIcon("drop")
        let filled = menuIcon("drop.fill")
        let levels = fillLevels(of: filled)
        return (0...progressSteps).map { step in
            let height = levels(CGFloat(step) / CGFloat(progressSteps))
            let image = NSImage(size: filled.size, flipped: false) { rect in
                outline.draw(in: rect)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: NSRect(x: 0, y: 0, width: rect.width, height: rect.height * height)).addClip()
                filled.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
                return true
            }
            image.isTemplate = true
            return image
        }
    }()

    /// Maps a progress fraction to the fill line (as a fraction of the image height) so the
    /// filled *area* of the drop matches the progress: the drop is widest at the bottom, so a
    /// height-proportional fill would look full at 60%.
    private static func fillLevels(of image: NSImage) -> (CGFloat) -> CGFloat {
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              bitmap.pixelsHigh > 0 else { return { $0 } }
        let rows = bitmap.pixelsHigh
        // Covered pixels per row, bottom row first.
        let coverage: [Int] = (0..<rows).map { fromBottom in
            let y = rows - 1 - fromBottom
            return (0..<bitmap.pixelsWide).reduce(0) { count, x in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 ? count + 1 : count
            }
        }
        let total = coverage.reduce(0, +)
        guard total > 0 else { return { $0 } }
        return { fraction in
            guard fraction > 0 else { return 0 }
            let target = Double(total) * Double(fraction)
            var sum = 0
            for (row, count) in coverage.enumerated() {
                sum += count
                if Double(sum) >= target { return CGFloat(row + 1) / CGFloat(rows) }
            }
            return 1
        }
    }

    private static func progressIcon(_ fraction: Double) -> NSImage {
        progressIcons[min(progressSteps, max(0, Int((fraction * Double(progressSteps)).rounded())))]
    }

    /// The menu bar shows state without opening anything: a drop filling up while receiving or
    /// sending, green while new devices can find this Mac.
    static func current(_ model: AppModel) -> (image: NSImage, label: String) {
        if let transfer = model.incomingTransfer, transfer.phase == .receiving {
            return (progressIcon(transfer.fraction), String(localized: "Dewlet — receiving"))
        }
        if let delivery = model.deliveries.first(where: { $0.phase == .sending }) {
            return (progressIcon(delivery.fraction), String(localized: "Dewlet — sending"))
        }
        if let packing = model.packings.first {
            return (progressIcon(packing.fraction ?? 0), String(localized: "Dewlet — packing a folder"))
        }
        if model.isPairingModeActive {
            return (visibleIcon, String(localized: "Dewlet — visible to new devices"))
        }
        return (idleIcon, "Dewlet")
    }
}
