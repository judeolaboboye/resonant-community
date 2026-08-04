struct WorkspaceCloudUploadOptions: Equatable {
    let includeContextMetadata: Bool
    let includeMeetingTranscripts: Bool
    let includeMeetingParticipants: Bool
    let includeSmartLinks: Bool
    let includeDictionary: Bool

    static let current = WorkspaceCloudUploadOptions(
        includeContextMetadata: false,
        includeMeetingTranscripts: true,
        includeMeetingParticipants: false,
        includeSmartLinks: true,
        includeDictionary: true
    )
}
