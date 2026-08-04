import Foundation

typealias MeetingSpeakerAliasMap = [String: String]

enum MeetingSpeakerAliasResolver {

    static func normalized(_ aliases: MeetingSpeakerAliasMap) -> MeetingSpeakerAliasMap {
        aliases.reduce(into: [:]) { result, entry in
            let storageKey = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let alias = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !storageKey.isEmpty, !alias.isEmpty else { return }
            result[storageKey] = alias
        }
    }

    static func mergedAliases(
        existing: MeetingSpeakerAliasMap,
        speakers: [MeetingSpeaker],
        captureContext: MeetingCaptureContext?,
        userDisplayName: String?,
        userEmail: String?
    ) -> MeetingSpeakerAliasMap {
        var merged = normalized(existing)
        let inferred = inferredAliases(
            speakers: speakers,
            captureContext: captureContext,
            userDisplayName: userDisplayName,
            userEmail: userEmail
        )
        for (storageKey, alias) in inferred where merged[storageKey] == nil {
            merged[storageKey] = alias
        }
        return merged
    }

    static func inferredAliases(
        speakers: [MeetingSpeaker],
        captureContext: MeetingCaptureContext?,
        userDisplayName: String?,
        userEmail: String?
    ) -> MeetingSpeakerAliasMap {
        let uniqueSpeakers = Array(Set(speakers)).sorted(by: speakerSort)
        guard !uniqueSpeakers.isEmpty else { return [:] }

        var aliases: MeetingSpeakerAliasMap = [:]

        if uniqueSpeakers.contains(.you),
           let localName = normalizedName(userDisplayName) {
            aliases[MeetingSpeaker.you.storageKey] = localName
        }

        let remoteSpeakers = uniqueSpeakers.filter { $0 != .you }
        let inferredRemoteNames = inferredRemoteNames(
            from: captureContext,
            userDisplayName: userDisplayName,
            userEmail: userEmail
        )

        for (speaker, name) in zip(remoteSpeakers, inferredRemoteNames) {
            aliases[speaker.storageKey] = name
        }

        return aliases
    }

    static func storageKey(forTranscriptLabel label: String, aliases: MeetingSpeakerAliasMap) -> String? {
        let reverseLookup = reverseLookupTable(from: aliases)
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let storageKey = reverseLookup[normalizedLabel] {
            return storageKey
        }
        return MeetingSpeaker.legacySpeaker(forTranscriptLabel: label)?.storageKey
    }

    static func reverseLookupTable(from aliases: MeetingSpeakerAliasMap) -> [String: String] {
        let normalizedAliases = normalized(aliases)
        var reverse: [String: String] = [:]
        var duplicates = Set<String>()

        for (storageKey, alias) in normalizedAliases {
            let normalizedAlias = alias.lowercased()
            if reverse[normalizedAlias] != nil {
                duplicates.insert(normalizedAlias)
            } else {
                reverse[normalizedAlias] = storageKey
            }
        }

        for duplicate in duplicates {
            reverse.removeValue(forKey: duplicate)
        }

        return reverse
    }

    private static func inferredRemoteNames(
        from captureContext: MeetingCaptureContext?,
        userDisplayName: String?,
        userEmail: String?
    ) -> [String] {
        guard let captureContext else { return [] }

        let localName = normalizedName(userDisplayName)
        let localEmail = normalizedEmail(userEmail)

        var orderedPeople: [String] = []
        func appendPerson(_ candidate: String?) {
            guard let candidate = normalizedName(candidate),
                  !orderedPeople.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame })
            else {
                return
            }
            orderedPeople.append(candidate)
        }

        appendPerson(captureContext.organizerName)
        captureContext.attendeeNames.forEach(appendPerson)

        let filteredByName = orderedPeople.filter { person in
            guard let localName else { return true }
            return person.caseInsensitiveCompare(localName) != .orderedSame
        }
        if !filteredByName.isEmpty {
            return filteredByName
        }

        if let localEmail,
           captureContext.attendeeEmails.map(normalizedEmail).contains(localEmail),
           let organizerName = normalizedName(captureContext.organizerName) {
            return [organizerName]
        }

        if captureContext.attendeeNames.count == 1,
           let onlyAttendee = normalizedName(captureContext.attendeeNames.first) {
            return [onlyAttendee]
        }

        if captureContext.attendeeNames.isEmpty,
           let organizerName = normalizedName(captureContext.organizerName) {
            return [organizerName]
        }

        return []
    }

    private static func speakerSort(_ lhs: MeetingSpeaker, _ rhs: MeetingSpeaker) -> Bool {
        speakerSortRank(lhs) < speakerSortRank(rhs)
    }

    private static func speakerSortRank(_ speaker: MeetingSpeaker) -> Int {
        switch speaker {
        case .you:
            return 0
        case .them:
            return 1
        case .participant(let id):
            if let index = MeetingSpeaker.participantIndex(for: id) {
                return 100 + index
            }
            return 999
        }
    }

    private static func normalizedName(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
