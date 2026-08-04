import OSLog

extension Logger {
    /// App-wide logging subsystem. Keep in sync with the bundle identifier so
    /// `log stream --predicate 'subsystem == "com.resonance.resonant"'` works.
    static let resonantSubsystem = "com.resonance.resonant"

    /// Creates a `Logger` in the app subsystem for the given category.
    /// Prefer this over `Logger(subsystem:category:)` so the subsystem string
    /// lives in exactly one place.
    static func resonant(_ category: String) -> Logger {
        Logger(subsystem: resonantSubsystem, category: category)
    }
}
