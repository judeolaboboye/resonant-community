import Foundation
@testable import Resonant

/// Shared fixtures for screen-context bias and vocabulary-boost audit tests.
enum ScreenContextBiasTestSupport {
    static func screenEntity(
        value: String,
        type: ContextEntityType,
        confidence: Double,
        source: EvidenceSource = .visibleSnippet,
        trustTier: ContextTrustTier = .biasTerm,
        isSensitive: Bool = false
    ) -> ContextEntity {
        ContextEntity(
            type: type,
            value: value,
            normalizedValue: value.lowercased(),
            spokenForms: [],
            source: source,
            confidence: confidence,
            recencyScore: 0.5,
            proximityScore: 0.5,
            trustTier: trustTier,
            isSensitive: isSensitive,
            evidence: "test fixture",
            surfaceScope: nil,
            appScope: nil,
            siteScope: nil,
            projectScope: nil
        )
    }

    static func correctionContext(entities: [ContextEntity]) -> CorrectionObservationContext {
        let surface = SurfaceDescriptor(
            kind: .chat,
            appName: "Slack",
            bundleId: "com.tinyspeck.slackmacgap",
            windowTitle: "#general - Slack",
            browserURL: nil,
            siteHost: nil,
            siteName: nil,
            fieldKind: .compose,
            conversationLabel: nil,
            documentLabel: nil,
            projectLabel: nil
        )
        let packet = ContextPacket(
            id: UUID(),
            capturedAt: Date(),
            surface: surface,
            intent: DictationIntent(
                kind: .plainDictation,
                confidence: 1,
                allowsBiasTerms: true,
                allowsStyleHint: true,
                allowsSelectedTextGrounding: true,
                allowsVisibleContextGrounding: true,
                allowsMemoryGrounding: true,
                evidence: []
            ),
            entities: entities,
            styleHint: nil,
            selectedTextPreview: nil,
            focusedFieldPreview: nil,
            visibleGroundingSnippets: [],
            safetyFlags: [],
            latency: .empty
        )
        return CorrectionObservationContext(
            appName: surface.appName,
            bundleId: surface.bundleId,
            windowTitle: surface.windowTitle,
            browserURL: nil,
            contextPacket: packet
        )
    }
}
