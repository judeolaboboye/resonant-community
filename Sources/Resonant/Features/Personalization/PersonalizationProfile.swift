import Defaults
import Foundation

extension Defaults.Keys {
    static let personalizationProfileSeed = Key<String?>(
        "personalizationProfileSeed",
        default: nil,
        suite: AppDefaults.suite
    )
}

enum PersonalizationProfileIdentity {
    static func seed() -> String {
        if let existing = Defaults[.personalizationProfileSeed]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }

        let generated = UUID().uuidString.lowercased()
        Defaults[.personalizationProfileSeed] = generated
        return generated
    }
}

enum PersonalizationProfileVariant: String, Codable, Sendable, Equatable {
    case personalized
    case holdout
}

/// Stable assignment contract for the context-only personalization policy.
///
/// The policy deliberately does not cover the manual dictionary, learned
/// formatter rules, or vocabulary boosting. Its default rollout has no
/// holdout until post-consumer exposure is wired and validated.
enum ContextPersonalizationPolicy {
    static let name = "context_personalization"
    static let version = 2
    static let defaultHoldoutRate = 0
}

struct PersonalizationProfileMetadata: Codable, Sendable, Hashable, Equatable {
    var schemaVersion: Int
    var source: String
    var variant: PersonalizationProfileVariant
    /// Assignment gate only. Consumer exposure is recorded separately.
    var isSelectedForPacket: Bool
    var profileHash: String
    var surfaceHash: String
    var holdoutBucket: Int
    var holdoutRate: Int
    var availableEntityCount: Int
    /// Pre-consumer selected candidate count. It is intentionally excluded
    /// from quality telemetry and never means that a consumer used a value.
    var selectedEntityCount: Int
    var styleHintAvailable: Bool
    var styleHintSelected: Bool
    var styleSampleCount: Int

    var assignmentPolicyName: String {
        ContextPersonalizationPolicy.name
    }

    var assignmentPolicyVersion: Int {
        schemaVersion
    }

    var assignedVariant: PersonalizationProfileVariant {
        variant
    }
}

struct VersionedPersonalizationProfile: Sendable, Equatable {
    var metadata: PersonalizationProfileMetadata
    var availableSnapshot: PersonalizationMemorySnapshot
}

enum PersonalizationProfileBuilder {
    static let schemaVersion = ContextPersonalizationPolicy.version
    static let assignmentPolicyName = ContextPersonalizationPolicy.name
    static let defaultHoldoutRate = ContextPersonalizationPolicy.defaultHoldoutRate

    static func build(
        surface: SurfaceDescriptor,
        snapshot: PersonalizationMemorySnapshot,
        styleSampleCount: Int,
        seed: String,
        holdoutRate: Int = defaultHoldoutRate
    ) -> VersionedPersonalizationProfile {
        let normalizedHoldoutRate = min(max(holdoutRate, 0), 100)
        let surfaceKey = Self.surfaceKey(for: surface)
        let bucket = bucketValue(seed: seed, surfaceKey: surfaceKey)
        let variant: PersonalizationProfileVariant = bucket < normalizedHoldoutRate ? .holdout : .personalized
        let isSelectedForPacket = variant == .personalized

        let metadata = PersonalizationProfileMetadata(
            schemaVersion: schemaVersion,
            source: "local",
            variant: variant,
            isSelectedForPacket: isSelectedForPacket,
            profileHash: profileHash(
                seed: seed,
                surfaceKey: surfaceKey,
                snapshot: snapshot,
                styleSampleCount: styleSampleCount
            ),
            surfaceHash: shortFingerprint("surface|\(seed)|\(surfaceKey)"),
            holdoutBucket: bucket,
            holdoutRate: normalizedHoldoutRate,
            availableEntityCount: snapshot.entities.count,
            selectedEntityCount: isSelectedForPacket ? snapshot.entities.count : 0,
            styleHintAvailable: snapshot.styleHint?.isEmpty == false,
            styleHintSelected: isSelectedForPacket && snapshot.styleHint?.isEmpty == false,
            styleSampleCount: styleSampleCount
        )

        return VersionedPersonalizationProfile(
            metadata: metadata,
            availableSnapshot: snapshot
        )
    }

    static func surfaceKey(for surface: SurfaceDescriptor) -> String {
        let scope: String
        if let siteHost = surface.siteHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !siteHost.isEmpty {
            scope = "site:\(siteHost)"
        } else if let bundleId = surface.bundleId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !bundleId.isEmpty {
            scope = "app:\(bundleId)"
        } else if let appName = surface.appName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !appName.isEmpty {
            scope = "app_name:\(appName)"
        } else {
            scope = "unknown"
        }

        let normalizedProject = surface.projectLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let project: String
        if let normalizedProject, !normalizedProject.isEmpty {
            project = normalizedProject
        } else {
            project = "none"
        }
        return [
            "schema:\(schemaVersion)",
            "kind:\(surface.kind.rawValue)",
            "field:\(surface.fieldKind.rawValue)",
            "scope:\(scope)",
            "project:\(project)"
        ].joined(separator: "|")
    }

    static func bucketValue(seed: String, surfaceKey: String) -> Int {
        Int(stableHash("\(assignmentPolicyName)|v\(schemaVersion)|\(seed)|\(surfaceKey)") % 100)
    }

    private static func profileHash(
        seed: String,
        surfaceKey: String,
        snapshot: PersonalizationMemorySnapshot,
        styleSampleCount: Int
    ) -> String {
        let entitySummary = snapshot.entities
            .map { entity in
                [
                    entity.type.rawValue,
                    entity.normalizedValue,
                    String(format: "%.3f", entity.confidence),
                    entity.appScope ?? "",
                    entity.siteScope ?? "",
                    entity.projectScope ?? ""
                ].joined(separator: ":")
            }
            .sorted()
            .joined(separator: "|")
        let biasSummary = snapshot.biasTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: "|")
        let styleSummary = snapshot.styleHint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let exemplarSummary = snapshot.editExemplars
            .map { "\($0.original)→\($0.edited)" }
            .joined(separator: "|")

        let canonical = [
            "schema:\(schemaVersion)",
            "surface:\(surfaceKey)",
            "entities:\(entitySummary)",
            "bias:\(biasSummary)",
            "style:\(styleSummary)",
            "style_samples:\(styleSampleCount)",
            "exemplars:\(exemplarSummary)"
        ].joined(separator: "\n")
        return shortFingerprint("profile|\(seed)|\(canonical)")
    }

    private static func shortFingerprint(_ value: String) -> String {
        let hex = String(stableHash(value), radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }
}
