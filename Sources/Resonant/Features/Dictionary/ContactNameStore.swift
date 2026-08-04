import Contacts
import Foundation
import Observation
import os

/// Opt-in, local-only import of names from the user's Contacts so dictation
/// can recognize the people they talk about. Names never leave the device:
/// they are stored as a JSON file in App Support and fed to the on-device
/// vocabulary-boost engine (after dictionary terms, which the user curated
/// explicitly and therefore outrank contacts under the term cap).
@MainActor
@Observable
final class ContactNameStore {

    typealias VocabularyTermsObserver = @MainActor () -> Void

    enum ImportError: LocalizedError {
        case accessDenied

        var errorDescription: String? {
            "Contacts access is off. Allow Resonant in System Settings → Privacy & Security → Contacts, then try again."
        }
    }

    /// Storage cap — generous headroom over the boost engine's own term cap so
    /// dictionary-term counts changing never starves contact coverage.
    static let maximumStoredNames = 200

    /// Single names shorter than this are skipped: short given names collide
    /// with common words ("Mark", "Will") and produce false rescues.
    static let minimumNameLength = 4

    private(set) var importedNames: [String] = [] {
        didSet { onVocabularyTermsChanged?() }
    }
    private(set) var lastImportedAt: Date?

    @ObservationIgnored var onVocabularyTermsChanged: VocabularyTermsObserver?

    private let log = Logger.resonant("ContactNameStore")
    private let storeURL: URL

    private struct Snapshot: Codable {
        let names: [String]
        let importedAt: Date
    }

    init(rootURL: URL = AppSupportPaths.resonantRoot()) {
        storeURL = rootURL.appendingPathComponent("contact-names.json")
        loadFromDisk()
    }

    var hasImported: Bool { lastImportedAt != nil }

    static var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    /// Requests access if needed, reads names, and persists them. Returns the
    /// number of stored names. Throws `ImportError.accessDenied` when the user
    /// declined the system prompt (or had previously denied it).
    @discardableResult
    func importFromSystemContacts() async throws -> Int {
        let store = CNContactStore()
        if Self.authorizationStatus == .notDetermined {
            _ = try? await store.requestAccess(for: .contacts)
        }
        guard Self.authorizationStatus == .authorized else {
            throw ImportError.accessDenied
        }

        let names = try await Task.detached(priority: .userInitiated) {
            try Self.fetchNames(from: store)
        }.value

        importedNames = names
        lastImportedAt = Date()
        persistToDisk()
        log.info("Imported \(names.count, privacy: .public) contact names")
        return names.count
    }

    func clear() {
        importedNames = []
        lastImportedAt = nil
        try? FileManager.default.removeItem(at: storeURL)
    }

    // MARK: - Name shaping

    nonisolated private static func fetchNames(from store: CNContactStore) throws -> [String] {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true

        var rawNames: [String] = []
        try store.enumerateContacts(with: request) { contact, _ in
            rawNames.append(contentsOf: candidateNames(
                given: contact.givenName,
                family: contact.familyName,
                nickname: contact.nickname,
                organization: contact.organizationName
            ))
        }
        return normalizedNames(rawNames)
    }

    /// Which spellable strings a single contact contributes. Full names are
    /// the primary signal; distinctive family names, nicknames, and org names
    /// help when the user says just one of them.
    nonisolated static func candidateNames(
        given: String,
        family: String,
        nickname: String,
        organization: String
    ) -> [String] {
        let given = given.trimmingCharacters(in: .whitespacesAndNewlines)
        let family = family.trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let organization = organization.trimmingCharacters(in: .whitespacesAndNewlines)

        var names: [String] = []
        if !given.isEmpty, !family.isEmpty {
            names.append("\(given) \(family)")
        }
        if family.count >= minimumNameLength {
            names.append(family)
        }
        if nickname.count >= minimumNameLength {
            names.append(nickname)
        }
        if organization.count >= minimumNameLength {
            names.append(organization)
        }
        return names
    }

    /// Dedupes case-insensitively, keeps only letter-bearing names long enough
    /// to be distinctive, and caps storage.
    nonisolated static func normalizedNames(_ rawNames: [String]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for raw in rawNames {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= minimumNameLength else { continue }
            guard trimmed.contains(where: { $0.isLetter }) else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            names.append(trimmed)
            if names.count >= maximumStoredNames { break }
        }
        return names
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storeURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return
        }
        importedNames = snapshot.names
        lastImportedAt = snapshot.importedAt
    }

    private func persistToDisk() {
        let snapshot = Snapshot(names: importedNames, importedAt: lastImportedAt ?? Date())
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try data.write(to: storeURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storeURL.path
            )
        } catch {
            log.error("Could not persist contact names: \(error.localizedDescription, privacy: .public)")
        }
    }
}
