import Foundation

enum MeetingTimelineSection: String, CaseIterable, Identifiable {
    case now = "Now"
    case upcoming = "Upcoming"
    case recent = "Recent"
    case earlier = "Earlier"
    case recorded = "Recorded"

    var id: String { rawValue }
}

enum MeetingTimelineStatus: Equatable {
    case recording
    case now
    case upcoming
    case missed
    case uncaptured
    case ignored
    case recorded
}

struct MeetingTimelineItem: Identifiable, Equatable {
    let id: String
    let section: MeetingTimelineSection
    let status: MeetingTimelineStatus
    let sortDate: Date
    let meeting: MeetingEntry?
    let calendarEvent: MeetingCalendarEvent?
    let hasActiveRecording: Bool
    let isBoundToActiveRecording: Bool

    var displayTitle: String {
        meeting?.displayTitle ?? calendarEvent?.title ?? "Meeting"
    }

    var organizerName: String? {
        meeting?.organizerName?.trimmedNilIfEmpty ?? calendarEvent?.organizerName?.trimmedNilIfEmpty
    }

    var attendeeNames: [String] {
        if let meeting, !meeting.attendeeNames.isEmpty {
            return meeting.attendeeNames
        }
        return calendarEvent?.attendeeNames ?? []
    }

    var detectedAppName: String? {
        meeting?.detectedApp?.trimmedNilIfEmpty
    }

    var startedAt: Date {
        meeting?.startedAt ?? calendarEvent?.startDate ?? sortDate
    }

    var endedAt: Date? {
        meeting?.endedAt ?? calendarEvent?.endDate
    }

    var durationText: String {
        if let meeting {
            return meeting.hasMeaningfulDuration ? meeting.formattedDuration : ""
        }
        if let calendarEvent {
            return "\(calendarEvent.durationMinutes) min"
        }
        return ""
    }

    var calendarEventID: String? {
        meeting?.calendarEventID ?? calendarEvent?.id
    }

    var conferencingURL: String? {
        meeting?.conferencingURL?.trimmedNilIfEmpty ?? calendarEvent?.conferencingURL?.trimmedNilIfEmpty
    }

    var canStartRecording: Bool {
        calendarEvent != nil && meeting == nil && !hasActiveRecording && !isBoundToActiveRecording
    }

    var canRebindRecording: Bool {
        calendarEvent != nil && meeting == nil && hasActiveRecording && !isBoundToActiveRecording
    }

    var isMissedLike: Bool {
        status == .missed || status == .ignored || status == .uncaptured
    }

    var hasConferencingURL: Bool {
        conferencingURL != nil
    }
}

enum MeetingTimelineBuilder {
    static let recentWindow: TimeInterval = 24 * 60 * 60
    static let earlierWindow: TimeInterval = 14 * 24 * 60 * 60

    static func build(
        calendarEvents: [MeetingCalendarEvent],
        meetings: [MeetingEntry],
        activeSession: MeetingSessionInfo?,
        hiddenCalendarEventIDs: Set<String>,
        ignoredCalendarEventIDs: Set<String>,
        now: Date = Date()
    ) -> [MeetingTimelineItem] {
        let recordedMeetings = meetings.sorted { $0.startedAt > $1.startedAt }
        let meetingsByCalendarID: [String: [MeetingEntry]] = Dictionary(
            grouping: recordedMeetings.compactMap { meeting -> (String, MeetingEntry)? in
                guard let calendarEventID = meeting.calendarEventID?.trimmedNilIfEmpty else { return nil }
                return (calendarEventID, meeting)
            },
            by: \.0
        ).mapValues { grouped in
            grouped.map(\.1).sorted { $0.startedAt > $1.startedAt }
        }
        let activeCalendarEventID = activeSession?.captureContext?.calendarEventID?.trimmedNilIfEmpty
        let hasActiveRecording = activeSession != nil

        var items: [MeetingTimelineItem] = []
        items.reserveCapacity(calendarEvents.count + recordedMeetings.count)

        for event in calendarEvents.sorted(by: { $0.startDate < $1.startDate }) {
            guard !hiddenCalendarEventIDs.contains(event.id) else { continue }
            let linkedMeeting = Self.linkedMeeting(
                for: event,
                meetingsByCalendarID: meetingsByCalendarID,
                recordedMeetings: recordedMeetings
            )

            if let linkedMeeting {
                if activeCalendarEventID == event.id {
                    items.append(MeetingTimelineItem(
                        id: "event:\(event.occurrenceKey)",
                        section: .now,
                        status: .recording,
                        sortDate: event.startDate,
                        meeting: linkedMeeting,
                        calendarEvent: event,
                        hasActiveRecording: hasActiveRecording,
                        isBoundToActiveRecording: true
                    ))
                }
                continue
            }

            let isBoundToActiveRecording = activeCalendarEventID == event.id
            let status: MeetingTimelineStatus
            let section: MeetingTimelineSection

            if isBoundToActiveRecording {
                status = .recording
                section = .now
            } else if event.isInProgress {
                status = .now
                section = .now
            } else if event.isUpcoming {
                status = .upcoming
                section = .upcoming
            } else if event.endDate >= now.addingTimeInterval(-recentWindow) {
                status = ignoredCalendarEventIDs.contains(event.id) ? .ignored : .missed
                section = .recent
            } else if event.endDate >= now.addingTimeInterval(-earlierWindow),
                      event.conferencingURL?.trimmedNilIfEmpty != nil {
                // Beyond the 24h "recent" window we only surface calls that had a
                // real conferencing URL — otherwise every social lunch shows up.
                if ignoredCalendarEventIDs.contains(event.id) { continue }
                status = .uncaptured
                section = .earlier
            } else {
                continue
            }

            items.append(MeetingTimelineItem(
                id: "event:\(event.occurrenceKey)",
                section: section,
                status: status,
                sortDate: event.startDate,
                meeting: nil,
                calendarEvent: event,
                hasActiveRecording: hasActiveRecording,
                isBoundToActiveRecording: isBoundToActiveRecording
            ))
        }

        for meeting in recordedMeetings where meeting.activeJSONLPath == nil {
            items.append(MeetingTimelineItem(
                id: "meeting:\(meeting.id.uuidString)",
                section: .recorded,
                status: .recorded,
                sortDate: meeting.startedAt,
                meeting: meeting,
                calendarEvent: nil,
                hasActiveRecording: hasActiveRecording,
                isBoundToActiveRecording: false
            ))
        }

        return items.sorted { lhs, rhs in
            if lhs.section != rhs.section {
                return sectionRank(lhs.section) < sectionRank(rhs.section)
            }
            switch lhs.section {
            case .now, .upcoming:
                return lhs.sortDate < rhs.sortDate
            case .recent, .earlier, .recorded:
                return lhs.sortDate > rhs.sortDate
            }
        }
    }

    private static func sectionRank(_ section: MeetingTimelineSection) -> Int {
        switch section {
        case .now: 0
        case .upcoming: 1
        case .recent: 2
        case .earlier: 3
        case .recorded: 4
        }
    }

    /// Tolerance for matching a recorded meeting to a recurring-event occurrence by start time.
    /// Wide enough to cover "started recording a few minutes late" but narrow enough that
    /// yesterday's gym recording never links to tomorrow's gym occurrence.
    private static let recurringOccurrenceMatchTolerance: TimeInterval = 60 * 60

    private static func linkedMeeting(
        for event: MeetingCalendarEvent,
        meetingsByCalendarID: [String: [MeetingEntry]],
        recordedMeetings: [MeetingEntry]
    ) -> MeetingEntry? {
        let sameSeries = meetingsByCalendarID[event.id] ?? []
        if event.isRecurring {
            // For recurring series, only link the recording whose startedAt sits on THIS
            // occurrence — otherwise every future gym row would collapse into the first
            // gym we ever recorded.
            return sameSeries.min { lhs, rhs in
                abs(lhs.startedAt.timeIntervalSince(event.startDate))
                    < abs(rhs.startedAt.timeIntervalSince(event.startDate))
            }.flatMap { candidate in
                abs(candidate.startedAt.timeIntervalSince(event.startDate))
                    <= recurringOccurrenceMatchTolerance ? candidate : nil
            }
        }
        if let first = sameSeries.first {
            return first
        }
        return recordedMeetings.first { meeting in
            meeting.startedAt == event.startDate && meeting.displayTitle == event.title
        }
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
