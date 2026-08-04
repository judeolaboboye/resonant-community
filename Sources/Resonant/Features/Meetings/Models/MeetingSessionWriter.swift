import Foundation

/// Append-only JSONL writer for meeting session utterances.
/// Thread-safe via actor isolation — both mic and system channels can call `append` concurrently.
actor MeetingSessionWriter {

    private let fileURL: URL
    private var fileHandle: FileHandle?
    private var utterances: [MeetingUtterance] = []
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init(sessionID: UUID) throws {
        let dir = AppSupportPaths.resonantRoot()
            .appendingPathComponent("meetings-active", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("\(sessionID.uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [
            .posixPermissions: 0o600
        ])
        fileHandle = try FileHandle(forWritingTo: url)
        fileURL = url
    }

    /// Relative path under App Support for persistence in MeetingEntry.
    var relativePath: String {
        "meetings-active/\(fileURL.lastPathComponent)"
    }

    var recordedUtterances: [MeetingUtterance] { utterances }

    func append(_ utterance: MeetingUtterance) {
        utterances.append(utterance)

        let record = MeetingSessionRecord(
            speaker: utterance.speaker,
            text: utterance.text,
            timestamp: utterance.timestamp
        )

        guard let data = try? encoder.encode(record) else { return }
        var line = data
        line.append(contentsOf: "\n".utf8)
        fileHandle?.write(line)
    }

    func flush() {
        fileHandle?.synchronizeFile()
    }

    /// Flush and close. Returns all utterances for markdown export.
    func close() -> [MeetingUtterance] {
        flush()
        fileHandle?.closeFile()
        fileHandle = nil
        return utterances
    }

    /// Delete the JSONL file after successful finalization.
    func deleteFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Crash Recovery

    /// Reconstruct utterances from an orphaned JSONL file.
    static func reconstruct(from url: URL) -> [MeetingUtterance] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let lines = data.split(separator: UInt8(ascii: "\n"))
        var utterances: [MeetingUtterance] = []
        for line in lines {
            guard let record = try? decoder.decode(MeetingSessionRecord.self, from: Data(line)) else {
                continue
            }
            utterances.append(MeetingUtterance(
                text: record.text,
                speaker: record.speaker,
                timestamp: record.timestamp
            ))
        }
        return utterances
    }
}
