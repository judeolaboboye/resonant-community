import EventKit
import Foundation
import os

struct MeetingCalendarHint: Sendable, Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let organizerName: String?
    let attendeeNames: [String]
    let attendeeEmails: [String]
    let conferencingURL: String?
    let calendarName: String?
    let searchableText: String

    init(
        id: String = UUID().uuidString,
        title: String,
        startDate: Date,
        endDate: Date,
        organizerName: String? = nil,
        attendeeNames: [String] = [],
        attendeeEmails: [String] = [],
        conferencingURL: String? = nil,
        calendarName: String? = nil,
        searchableText: String
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.organizerName = organizerName
        self.attendeeNames = attendeeNames
        self.attendeeEmails = attendeeEmails
        self.conferencingURL = conferencingURL
        self.calendarName = calendarName
        self.searchableText = searchableText
    }

    func captureContext(origin: MeetingRecordingOrigin, titleOverride: String? = nil) -> MeetingCaptureContext {
        MeetingCaptureContext(
            calendarEventID: id,
            scheduledStartAt: startDate,
            scheduledEndAt: endDate,
            organizerName: organizerName?.trimmedNilIfEmpty,
            attendeeNames: attendeeNames,
            attendeeEmails: attendeeEmails,
            conferencingURL: conferencingURL?.trimmedNilIfEmpty,
            calendarName: calendarName?.trimmedNilIfEmpty,
            title: titleOverride?.trimmedNilIfEmpty ?? title,
            recordingOrigin: origin
        )
    }
}

/// A calendar event displayed in the Meetings tab — broader than a detection hint.
/// Includes upcoming, in-progress, and recently ended events.
struct MeetingCalendarEvent: Identifiable, Sendable, Equatable {
    let id: String          // EKEvent.eventIdentifier (shared across recurring occurrences)
    let title: String
    let startDate: Date
    let endDate: Date
    let organizerName: String?
    let attendeeNames: [String]
    let attendeeEmails: [String]
    let conferencingURL: String?
    let calendarName: String?
    let calendarColor: UInt?  // ARGB packed
    let isRecurring: Bool

    /// Per-occurrence key. EKEvent.eventIdentifier is the same for every occurrence of a
    /// recurring event, so we suffix with startDate to disambiguate instances in lists.
    var occurrenceKey: String {
        "\(id)#\(Int(startDate.timeIntervalSince1970))"
    }

    var isInProgress: Bool {
        let now = Date()
        return now >= startDate && now <= endDate
    }

    var isUpcoming: Bool {
        Date() < startDate
    }

    var isPast: Bool {
        Date() > endDate
    }

    var durationMinutes: Int {
        Int(endDate.timeIntervalSince(startDate) / 60)
    }

    var hint: MeetingCalendarHint {
        let searchableFields: [String?] = [
            title,
            organizerName,
            attendeeNames.joined(separator: " "),
            attendeeEmails.joined(separator: " "),
            conferencingURL,
            calendarName,
        ]
        return MeetingCalendarHint(
            id: id,
            title: title,
            startDate: startDate,
            endDate: endDate,
            organizerName: organizerName,
            attendeeNames: attendeeNames,
            attendeeEmails: attendeeEmails,
            conferencingURL: conferencingURL,
            calendarName: calendarName,
            searchableText: searchableFields
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .lowercased()
        )
    }

    func captureContext(origin: MeetingRecordingOrigin, titleOverride: String? = nil) -> MeetingCaptureContext {
        MeetingCaptureContext(
            calendarEventID: id,
            scheduledStartAt: startDate,
            scheduledEndAt: endDate,
            organizerName: organizerName?.trimmedNilIfEmpty,
            attendeeNames: attendeeNames,
            attendeeEmails: attendeeEmails,
            conferencingURL: conferencingURL?.trimmedNilIfEmpty,
            calendarName: calendarName?.trimmedNilIfEmpty,
            title: titleOverride?.trimmedNilIfEmpty ?? title,
            recordingOrigin: origin
        )
    }
}

/// UI-friendly authorization state, independent of EventKit.
enum MeetingCalendarAuthorizationStatus: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
}

struct MeetingCalendarEventRefreshSummary: Sendable, Equatable {
    let authorizationStatus: MeetingCalendarAuthorizationStatus
    let startDate: Date
    let endDate: Date
    let didFetchEvents: Bool
    let fetchedEventCount: Int
    let nonAllDayEventCount: Int
    let meetingLikeEventCount: Int
    let returnedEventCount: Int
}

struct MeetingCalendarEventRefreshResult: Sendable, Equatable {
    let events: [MeetingCalendarEvent]
    let summary: MeetingCalendarEventRefreshSummary
}

@MainActor
protocol MeetingCalendarHintSource: AnyObject {
    var authorizationStatus: MeetingCalendarAuthorizationStatus { get }
    func requestAuthorizationIfNeeded() async -> Bool
    func activeMeetingHints(now: Date) async -> [MeetingCalendarHint]
    func calendarEvents(from startDate: Date, to endDate: Date) async -> [MeetingCalendarEvent]
}

@MainActor
final class EventKitMeetingCalendarHintSource: MeetingCalendarHintSource {

    private let eventStore: EKEventStore
    private nonisolated static let diagnosticsLog = Logger(
        subsystem: "com.resonance.resonant",
        category: "meeting.calendar"
    )
    private nonisolated static let calendarSignposter = OSSignposter(
        subsystem: "com.resonance.resonant",
        category: "meeting.calendar"
    )

    private nonisolated static let earlyStartLeadTime: TimeInterval = 10 * 60
    private nonisolated static let lateEndGracePeriod: TimeInterval = 15 * 60
    private nonisolated static let fetchLookback: TimeInterval = 30 * 60
    private nonisolated static let fetchLookahead: TimeInterval = 8 * 60 * 60

    /// Window for the Meetings tab calendar view.
    /// Lookback reaches back 14 days so "earlier" section can surface past calls
    /// that had conferencing links but were never recorded. Lookahead covers the
    /// next 7 days so the whole week is visible.
    private nonisolated static let tabLookback: TimeInterval = 14 * 24 * 60 * 60
    private nonisolated static let tabLookahead: TimeInterval = 7 * 24 * 60 * 60

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .writeOnly, .restricted, .denied:
            return false
        case .notDetermined:
            return (try? await eventStore.requestFullAccessToEvents()) ?? false
        @unknown default:
            return false
        }
    }

    func activeMeetingHints(now: Date = Date()) async -> [MeetingCalendarHint] {
        guard authorizationStatus == .authorized else { return [] }
        return await Self.fetchActiveMeetingHintsOffMain(now: now)
    }

    func calendarEvents(from startDate: Date, to endDate: Date) async -> [MeetingCalendarEvent] {
        await calendarEventRefreshResult(from: startDate, to: endDate).events
    }

    func calendarEventRefreshResult(from startDate: Date, to endDate: Date) async -> MeetingCalendarEventRefreshResult {
        let status = authorizationStatus
        guard status == .authorized else {
            return MeetingCalendarEventRefreshResult(
                events: [],
                summary: MeetingCalendarEventRefreshSummary(
                    authorizationStatus: status,
                    startDate: startDate,
                    endDate: endDate,
                    didFetchEvents: false,
                    fetchedEventCount: 0,
                    nonAllDayEventCount: 0,
                    meetingLikeEventCount: 0,
                    returnedEventCount: 0
                )
            )
        }

        return await Self.fetchCalendarEventRefreshResultOffMain(
            startDate: startDate,
            endDate: endDate,
            authorizationStatus: status
        )
    }

    /// Fetches calendar events for the Meetings tab: past 14 days + next 7 days.
    func calendarEventsForMeetingsTab(now: Date = Date()) async -> [MeetingCalendarEvent] {
        await calendarEvents(
            from: now.addingTimeInterval(-Self.tabLookback),
            to: now.addingTimeInterval(Self.tabLookahead)
        )
    }

    func calendarEventRefreshResultForMeetingsTab(now: Date = Date()) async -> MeetingCalendarEventRefreshResult {
        await calendarEventRefreshResult(
            from: now.addingTimeInterval(-Self.tabLookback),
            to: now.addingTimeInterval(Self.tabLookahead)
        )
    }

    var authorizationStatus: MeetingCalendarAuthorizationStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            .authorized
        case .notDetermined:
            .notDetermined
        case .writeOnly, .restricted, .denied:
            .denied
        @unknown default:
            .denied
        }
    }

    private nonisolated static func fetchActiveMeetingHintsOffMain(now: Date) async -> [MeetingCalendarHint] {
        await Task.detached(priority: .utility) {
            let startedAt = ContinuousClock.now
            let signpostID = calendarSignposter.makeSignpostID()
            calendarSignposter.emitEvent("calendar.activeHints.start", id: signpostID)
            let eventStore = EKEventStore()
            let predicate = eventStore.predicateForEvents(
                withStart: now.addingTimeInterval(-fetchLookback),
                end: now.addingTimeInterval(fetchLookahead),
                calendars: nil
            )

            let fetchedEvents = eventStore.events(matching: predicate)
            let hints = fetchedEvents
                .filter { isRelevantMeetingEvent($0, now: now) }
                .compactMap(makeHint(from:))
                .sorted { lhs, rhs in
                    if lhs.startDate != rhs.startDate {
                        return lhs.startDate < rhs.startDate
                    }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
            logCalendarFetch(
                kind: "activeHints",
                fetchedCount: fetchedEvents.count,
                nonAllDayCount: fetchedEvents.filter { !$0.isAllDay }.count,
                meetingLikeCount: hints.count,
                returnedCount: hints.count,
                milliseconds: DiagnosticTiming.milliseconds(from: startedAt)
            )
            calendarSignposter.emitEvent("calendar.activeHints.finish", id: signpostID)
            return hints
        }.value
    }

    private nonisolated static func fetchCalendarEventRefreshResultOffMain(
        startDate: Date,
        endDate: Date,
        authorizationStatus: MeetingCalendarAuthorizationStatus
    ) async -> MeetingCalendarEventRefreshResult {
        await Task.detached(priority: .utility) {
            let startedAt = ContinuousClock.now
            let signpostID = calendarSignposter.makeSignpostID()
            calendarSignposter.emitEvent("calendar.refresh.start", id: signpostID)
            let eventStore = EKEventStore()
            let predicate = eventStore.predicateForEvents(
                withStart: startDate,
                end: endDate,
                calendars: nil
            )

            let fetchedEvents = eventStore.events(matching: predicate)
            let nonAllDayEvents = fetchedEvents.filter { !$0.isAllDay }
            let meetingLikeEvents = nonAllDayEvents.filter { isMeetingLikeEvent($0) }
            let events = meetingLikeEvents
                .compactMap(makeCalendarEvent(from:))
                .sorted { $0.startDate < $1.startDate }
            logCalendarFetch(
                kind: "refresh",
                fetchedCount: fetchedEvents.count,
                nonAllDayCount: nonAllDayEvents.count,
                meetingLikeCount: meetingLikeEvents.count,
                returnedCount: events.count,
                milliseconds: DiagnosticTiming.milliseconds(from: startedAt)
            )
            calendarSignposter.emitEvent("calendar.refresh.finish", id: signpostID)

            return MeetingCalendarEventRefreshResult(
                events: events,
                summary: MeetingCalendarEventRefreshSummary(
                    authorizationStatus: authorizationStatus,
                    startDate: startDate,
                    endDate: endDate,
                    didFetchEvents: true,
                    fetchedEventCount: fetchedEvents.count,
                    nonAllDayEventCount: nonAllDayEvents.count,
                    meetingLikeEventCount: meetingLikeEvents.count,
                    returnedEventCount: events.count
                )
            )
        }.value
    }

    private nonisolated static func logCalendarFetch(
        kind: String,
        fetchedCount: Int,
        nonAllDayCount: Int,
        meetingLikeCount: Int,
        returnedCount: Int,
        milliseconds: Int64
    ) {
        let line = "\(kind) fetched=\(fetchedCount) nonAllDay=\(nonAllDayCount) meetingLike=\(meetingLikeCount) returned=\(returnedCount) total=\(milliseconds)ms"
        diagnosticsLog.info("calendar.fetch \(line, privacy: .public)")
        NSLog("[MeetingCalendar] fetch %@", line)
    }

    private nonisolated static func isRelevantMeetingEvent(_ event: EKEvent, now: Date) -> Bool {
        guard !event.isAllDay else { return false }

        let earliestConsideredStart = event.startDate.addingTimeInterval(-earlyStartLeadTime)
        let latestConsideredEnd = event.endDate.addingTimeInterval(lateEndGracePeriod)
        guard now >= earliestConsideredStart, now <= latestConsideredEnd else { return false }

        let searchableText = normalizedSearchText(
            title: event.title,
            location: event.location,
            notes: event.notes,
            eventURL: event.url?.absoluteString
        )

        if extractedMeetingURL(from: event) != nil {
            return true
        }

        if searchableText.containsAny(of: providerKeywords) {
            return true
        }

        return !(event.attendees ?? []).isEmpty
    }

    private nonisolated static func makeHint(from event: EKEvent) -> MeetingCalendarHint? {
        let normalizedTitle = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedTitle.isEmpty else { return nil }
        let attendees = calendarAttendees(from: event)

        return MeetingCalendarHint(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: normalizedTitle,
            startDate: event.startDate,
            endDate: event.endDate,
            organizerName: event.organizer?.name,
            attendeeNames: attendees.names,
            attendeeEmails: attendees.emails,
            conferencingURL: extractedMeetingURL(from: event),
            calendarName: event.calendar?.title,
            searchableText: normalizedSearchText(
                title: event.title,
                location: event.location,
                notes: event.notes,
                eventURL: event.url?.absoluteString
            )
        )
    }

    private nonisolated static func normalizedSearchText(
        title: String?,
        location: String?,
        notes: String?,
        eventURL: String?
    ) -> String {
        [title, location, notes, eventURL]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    private nonisolated static func extractedMeetingURL(from event: EKEvent) -> String? {
        if let eventURL = normalizedMeetingURL(event.url?.absoluteString) {
            return eventURL
        }

        let candidates = [event.location, event.notes]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap(extractURLs(from:))

        return candidates.first(where: { normalizedMeetingURL($0) != nil }).flatMap(normalizedMeetingURL)
    }

    private nonisolated static func extractURLs(from text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: range).compactMap { match in
            match.url?.absoluteString
        }
    }

    nonisolated static func normalizedMeetingURL(_ rawURL: String?) -> String? {
        guard let rawURL else { return nil }
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: withScheme),
              let host = components.host?.lowercased(),
              host.contains(".")
        else {
            return nil
        }

        guard host.hasSuffix("meet.google.com")
            || host == "zoom.us"
            || host.hasSuffix(".zoom.us")
            || host == "teams.microsoft.com"
            || host == "teams.live.com"
            || host == "meet.proton.me"
            || host == "webex.com"
            || host.hasSuffix(".webex.com")
            || host == "v.ringcentral.com"
            || host == "meetings.ringcentral.com"
            || host == "app.ringcentral.com"
            || host == "global.gotomeeting.com"
            || host == "app.gotomeeting.com"
            || host == "meet.goto.com"
            || host == "gotomeet.me"
            || host == "meet.jit.si"
            || host == "8x8.vc"
            || host.hasSuffix(".8x8.vc")
            || host == "whereby.com"
            || host.hasSuffix(".whereby.com")
            || host == "app.chime.aws"
            || host == "chime.aws"
            || host == "meeting.zoho.com"
            || host == "meet.zoho.com"
            || host == "meetings.dialpad.com"
        else {
            return nil
        }

        return withScheme
    }

    private nonisolated static let providerKeywords = [
        "google meet",
        "meet.google.com",
        "zoom",
        "teams",
        "microsoft teams",
        "proton meet",
        "meet.proton.me",
        "webex",
        "facetime",
        "slack huddle",
        "discord call",
        "ringcentral",
        "goto meeting",
        "gotomeeting",
        "jitsi",
        "meet.jit.si",
        "whereby",
        "amazon chime",
        "chime.aws",
        "zoho meeting",
        "dialpad meetings",
    ]

    // MARK: - Calendar Event Helpers

    /// Broader filter than isRelevantMeetingEvent — includes any event that looks like a meeting
    /// (has attendees, a conferencing URL, or meeting keywords). Used for the Meetings tab.
    private nonisolated static func isMeetingLikeEvent(_ event: EKEvent) -> Bool {
        if extractedMeetingURL(from: event) != nil {
            return true
        }

        let searchableText = normalizedSearchText(
            title: event.title,
            location: event.location,
            notes: event.notes,
            eventURL: event.url?.absoluteString
        )

        if searchableText.containsAny(of: providerKeywords) {
            return true
        }

        return !(event.attendees ?? []).isEmpty
    }

    private nonisolated static func makeCalendarEvent(from event: EKEvent) -> MeetingCalendarEvent? {
        let normalizedTitle = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedTitle.isEmpty else { return nil }

        let attendees = calendarAttendees(from: event)
        let organizerName = event.organizer?.name

        var calendarColorARGB: UInt?
        if let cgColor = event.calendar?.cgColor,
           let cs = CGColorSpace(name: CGColorSpace.sRGB),
           let c = cgColor.converted(to: cs, intent: .defaultIntent, options: nil),
           let comp = c.components, c.numberOfComponents >= 3 {
            let r = UInt(comp[0] * 255)
            let g = UInt(comp[1] * 255)
            let b = UInt(comp[2] * 255)
            let a = UInt((c.numberOfComponents >= 4 ? comp[3] : 1.0) * 255)
            calendarColorARGB = (a << 24) | (r << 16) | (g << 8) | b
        }

        return MeetingCalendarEvent(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: normalizedTitle,
            startDate: event.startDate,
            endDate: event.endDate,
            organizerName: organizerName,
            attendeeNames: attendees.names,
            attendeeEmails: attendees.emails,
            conferencingURL: extractedMeetingURL(from: event),
            calendarName: event.calendar?.title,
            calendarColor: calendarColorARGB,
            isRecurring: event.hasRecurrenceRules
        )
    }

    private nonisolated static func calendarAttendees(from event: EKEvent) -> (names: [String], emails: [String]) {
        let filteredAttendees = (event.attendees ?? []).filter { $0.participantRole != .nonParticipant }
        let names = filteredAttendees.compactMap { attendee in
            attendee.name?.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNilIfEmpty
                ?? attendee.url.absoluteString
                    .replacingOccurrences(of: "mailto:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmedNilIfEmpty
        }
        let emails = filteredAttendees.compactMap { attendee in
            attendee.url.absoluteString
                .replacingOccurrences(of: "mailto:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmedNilIfEmpty
        }
        return (Array(Set(names)).sorted(), Array(Set(emails)).sorted())
    }
}

private extension String {
    func containsAny(of values: [String]) -> Bool {
        values.contains { contains($0) }
    }

    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
