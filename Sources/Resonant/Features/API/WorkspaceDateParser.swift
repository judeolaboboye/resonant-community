import Foundation

/// Parses the flexible date strings accepted by workspace tools.
///
/// The parser is intentionally pure so tool argument parsing can be tested
/// without constructing a workspace query engine or touching persistence.
struct WorkspaceDateParser: Sendable {
    let now: Date
    let calendar: Calendar

    init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    static func parse(_ string: String) -> Date? {
        WorkspaceDateParser().parse(string)
    }

    func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        switch lowered {
        case "today":
            return calendar.startOfDay(for: now)
        case "yesterday":
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        case "now":
            return now
        default:
            break
        }

        if lowered.count >= 2 {
            let unit = lowered.last!
            if let value = Int(lowered.dropLast()), value > 0 {
                switch unit {
                case "h":
                    return calendar.date(byAdding: .hour, value: -value, to: now)
                case "d":
                    return calendar.date(byAdding: .day, value: -value, to: now)
                case "w":
                    return calendar.date(byAdding: .day, value: -value * 7, to: now)
                case "m":
                    return calendar.date(byAdding: .month, value: -value, to: now)
                default:
                    break
                }
            }
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }

        let ymd = makeDateFormatter(format: "yyyy-MM-dd")
        if let date = ymd.date(from: lowered) { return date }

        let ymdhm = makeDateFormatter(format: "yyyy-MM-dd HH:mm")
        if let date = ymdhm.date(from: lowered) { return date }

        return nil
    }

    private func makeDateFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        return formatter
    }
}
