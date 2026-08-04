import CryptoKit
import Foundation

/// Immutable on-disk SwiftData store created from the personalization schema
/// that predated the personalization-truth migration. Tests must materialize
/// these bytes instead of constructing the legacy rows with current models.
enum LegacyPersonalizationStoreFixture {
    struct Copy {
        let directoryURL: URL
        let storeURL: URL

        func remove(fileManager: FileManager = .default) {
            try? fileManager.removeItem(at: directoryURL)
        }
    }

    enum Baseline {
        static let entityID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        static let styleProfileID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        static let punctuationPreferenceID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        static let wordCasingPreferenceID = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        static let correctionEventID = UUID(uuidString: "10000000-0000-0000-0000-000000000005")!
        static let dictionaryWordID = UUID(uuidString: "10000000-0000-0000-0000-000000000006")!
        static let dictationID = UUID(uuidString: "10000000-0000-0000-0000-000000000007")!
    }

    private enum FixtureError: LocalizedError {
        case invalidBase64
        case unexpectedStoreSize(Int)
        case checksumMismatch(String)
        case destinationAlreadyExists(URL)

        var errorDescription: String? {
            switch self {
            case .invalidBase64:
                "Legacy personalization fixture is not valid base64"
            case let .unexpectedStoreSize(size):
                "Legacy personalization fixture has unexpected size: \(size) bytes"
            case let .checksumMismatch(checksum):
                "Legacy personalization fixture checksum mismatch: \(checksum)"
            case let .destinationAlreadyExists(url):
                "Legacy personalization fixture destination already exists: \(url.path)"
            }
        }
    }

    static let uncompressedByteCount = 122_880
    static let uncompressedSHA256 = "b1ccd6ea9eb61e478bf59c6f4f231f1b26db2e831f32385437932c7cdbad93db"

    static func makeCopy(fileManager: FileManager = .default) throws -> Copy {
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("LegacyPersonalization-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let storeURL = directoryURL.appendingPathComponent("Resonant.store")

        do {
            try materialize(at: storeURL, fileManager: fileManager)
            return Copy(directoryURL: directoryURL, storeURL: storeURL)
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    static func materialize(
        at storeURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let destinationFamily = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-shm"),
            URL(fileURLWithPath: storeURL.path + "-wal"),
        ]
        if let existingURL = destinationFamily.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) {
            throw FixtureError.destinationAlreadyExists(existingURL)
        }

        let encoded = LegacyPersonalizationStoreFixtureBytes.encoded
        guard let compressed = Data(
            base64Encoded: encoded,
            options: .ignoreUnknownCharacters
        ) else {
            throw FixtureError.invalidBase64
        }

        let storeData = try (compressed as NSData).decompressed(using: .zlib) as Data
        guard storeData.count == uncompressedByteCount else {
            throw FixtureError.unexpectedStoreSize(storeData.count)
        }

        let checksum = SHA256.hash(data: storeData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard checksum == uncompressedSHA256 else {
            throw FixtureError.checksumMismatch(checksum)
        }

        try fileManager.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try storeData.write(to: storeURL, options: .atomic)
    }
}
