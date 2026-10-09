import Foundation

/// Roughly how long a transfer still takes, from its recent speed: whole seconds up to 10, then
/// in steps of 5 seconds, then in minutes, so the number doesn't jitter.
nonisolated enum TimeLeft {
    static func text(remainingBytes: Int64, bytesPerSecond: Double) -> String? {
        guard bytesPerSecond > 0, remainingBytes > 0 else { return nil }
        let seconds = Double(remainingBytes) / bytesPerSecond
        let rounded = switch seconds {
        case ..<10: max(1, Int(seconds.rounded(.up)))
        case ..<60: Int((seconds / 5).rounded(.up)) * 5
        default: Int((seconds / 60).rounded(.up)) * 60
        }
        let duration = Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))
        return String(localized: "about \(duration) left")
    }
}
