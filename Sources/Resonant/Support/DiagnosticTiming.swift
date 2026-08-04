import Foundation

enum DiagnosticTiming {
    static func milliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant = .now
    ) -> Int64 {
        let components = start.duration(to: end).components
        return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }
}
