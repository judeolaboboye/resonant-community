import Foundation

/// Preset that controls the prompt template used when summarizing meetings.
enum MeetingSummaryStyle: String, CaseIterable, Identifiable, Sendable {
    case standard
    case decisionsActions
    case detailedNotes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard:         "Standard"
        case .decisionsActions: "Decisions & actions"
        case .detailedNotes:    "Detailed notes"
        }
    }

    var detail: String {
        switch self {
        case .standard:
            "Concise 3–5 bullet recap with the main discussion points."
        case .decisionsActions:
            "Just what was decided and who owns the follow-ups."
        case .detailedNotes:
            "Longer minutes-style notes organized by topic."
        }
    }

    var promptInstructions: String {
        switch self {
        case .standard:
            return """
            Produce a useful post-meeting artifact from this transcript.
            Use markdown sections: Summary, Decisions, Action items, Open questions.
            In Summary, write 4-7 concrete bullets covering substantive discussion, disagreements, outcomes, and follow-up context.
            In Decisions, list what was actually decided; write "None stated" if nothing landed.
            In Action items, use "Task - Owner: name or Unassigned - Due: date or Not stated".
            Stay factual. Do not invent owners, dates, decisions, or attendee names.
            """
        case .decisionsActions:
            return """
            Extract only decisions, action items, and unresolved questions from this transcript.
            Use markdown sections: Decisions, Action items, Open questions.
            Each decision should include an owner only when stated.
            Each action item should use "Task - Owner: name or Unassigned - Due: date or Not stated".
            Skip small talk and discussion that did not land on a decision, task, risk, or blocker.
            Stay factual. Do not invent owners, dates, decisions, or attendee names.
            """
        case .detailedNotes:
            return """
            Produce detailed meeting notes from this transcript.
            Use markdown sections: Executive summary, Topic notes, Decisions, Action items, Open questions.
            Group Topic notes by actual topics from the meeting and capture key facts, tradeoffs, objections, and outcomes.
            Include all decisions and concrete follow-ups with owners and due dates when stated.
            Aim for thorough coverage rather than brevity, but stay factual. Do not invent details.
            """
        }
    }
}
