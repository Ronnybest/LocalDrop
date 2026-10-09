import Foundation

/// Roughly how long a transfer still takes, from its recent speed, rounded up so the number
/// doesn't jitter: whole seconds up to 10, steps of 5 seconds up to a minute, then minutes and
/// seconds in steps of 15 (so it moves about every 15 seconds), from an hour hours and minutes.
nonisolated enum TimeLeft {
    static func text(remainingBytes: Int64, bytesPerSecond: Double) -> String? {
        guard bytesPerSecond > 0, remainingBytes > 0 else { return nil }
        let seconds = Double(remainingBytes) / bytesPerSecond
        let step: Double = switch seconds {
        case ..<10: 1
        case ..<60: 5
        case ..<3600: 15
        default: 60
        }
        let rounded = max(1, Int((seconds / step).rounded(.up) * step))
        let units: Set<Duration.UnitsFormatStyle.Unit> = rounded < 3600 ? [.minutes, .seconds] : [.hours, .minutes]
        let duration = Duration.seconds(rounded).formatted(.units(allowed: units, width: .abbreviated, maximumUnitCount: 2))
        return String(localized: "about \(duration) left")
    }
}
