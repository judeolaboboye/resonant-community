import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import CryptoKit
import ObjCExceptionCatcher
import os

/// Pastes text into the frontmost app using CGEvent keyboard simulation.
/// Uses a transient pasteboard type to avoid polluting clipboard history managers.
final class PasteManager {

    private static let log = Logger.resonant("PasteManager")

    enum DeliveryFailure: Equatable {
        case accessibilityPermissionRequired
        case accessibilityPermissionStale
        case targetActivationFailed
        case noFrontmostTarget
        case deliveryUnverified
        case writeFailed
        case secureInputActive
        case partialDelivery
    }

    /// Privacy-preserving evidence around a delivered text region. All offsets
    /// are expressed in UTF-16, matching Accessibility ranges. Surrounding field
    /// text is hashed immediately and never retained in the receipt.
    struct UTF16InsertionAnchor: Sendable, Equatable {
        let replacedRange: SelectionRange
        let prefixUTF16Length: Int
        let suffixUTF16Length: Int
        private let prefixDigest: Data
        private let suffixDigest: Data

        init(replacedRange: SelectionRange, prefix: String, suffix: String) {
            self.replacedRange = replacedRange
            self.prefixUTF16Length = (prefix as NSString).length
            self.suffixUTF16Length = (suffix as NSString).length
            self.prefixDigest = Self.digest(prefix)
            self.suffixDigest = Self.digest(suffix)
        }

        var hasClosedBoundaries: Bool {
            prefixUTF16Length > 0 && suffixUTF16Length > 0
        }

        fileprivate func matches(prefix: String, suffix: String) -> Bool {
            Self.digest(prefix) == prefixDigest && Self.digest(suffix) == suffixDigest
        }

        private static func digest(_ value: String) -> Data {
            Data(SHA256.hash(data: Data(value.utf8)))
        }
    }

    /// Evidence captured from the target itself after a successful delivery.
    /// A receipt is intentionally unavailable for unverified keyboard targets:
    /// both the pre-delivery and post-delivery values must come from the same
    /// retained AX element before correction learning can use it.
    struct DeliveryReceipt {
        let targetProcessIdentifier: pid_t
        let targetBundleIdentifier: String?
        let targetObservedInsertedText: String
        let anchor: UTF16InsertionAnchor

        fileprivate let element: AXUIElement
        fileprivate let windowTitle: String?
        fileprivate let browserURL: String?

        init(
            targetProcessIdentifier: pid_t,
            targetBundleIdentifier: String?,
            targetObservedInsertedText: String,
            anchor: UTF16InsertionAnchor,
            element: AXUIElement,
            windowTitle: String?,
            browserURL: String?
        ) {
            self.targetProcessIdentifier = targetProcessIdentifier
            self.targetBundleIdentifier = targetBundleIdentifier
            self.targetObservedInsertedText = targetObservedInsertedText
            self.anchor = anchor
            self.element = element
            self.windowTitle = windowTitle
            self.browserURL = browserURL
        }
    }

    struct DeliveryOutcome {
        /// Local correlation identifier. It is intentionally never included in
        /// analytics or remote request contracts.
        let deliveryAttemptID: UUID
        /// Source text supplied by the caller before any delivery transform.
        let requestedText: String?
        /// Plain text actually submitted to the target after smart spacing and
        /// Markdown-link stripping. Nil means no complete paste was delivered.
        let effectiveInsertedText: String?
        /// Immediate target-observed insertion, when AX evidence could isolate
        /// it without retaining surrounding field text.
        let targetObservedSettledText: String?
        /// Text-free delivery evidence usable by a later no-receipt readback.
        let deliveryAttribution: DeliveryAttribution?
        /// Text reached the target (or clipboard-only delivery completed).
        let delivered: Bool
        /// Return was posted when auto-send was requested. This is deliberately
        /// separate from `delivered`: a cancelled/failed send can leave text
        /// visibly pasted in the composer.
        let sent: Bool
        let partiallyDelivered: Bool
        let receipt: DeliveryReceipt?
        let targetProcessIdentifier: pid_t?
        let targetBundleIdentifier: String?

        init(
            delivered: Bool,
            sent: Bool = false,
            partiallyDelivered: Bool = false,
            receipt: DeliveryReceipt?,
            targetProcessIdentifier: pid_t? = nil,
            targetBundleIdentifier: String? = nil,
            deliveryAttemptID: UUID = UUID(),
            requestedText: String? = nil,
            effectiveInsertedText: String? = nil,
            targetObservedSettledText: String? = nil,
            deliveryAttribution: DeliveryAttribution? = nil
        ) {
            self.deliveryAttemptID = deliveryAttemptID
            self.requestedText = requestedText
            self.effectiveInsertedText = effectiveInsertedText
            self.targetObservedSettledText = targetObservedSettledText
                ?? receipt?.targetObservedInsertedText
            self.deliveryAttribution = deliveryAttribution
            self.delivered = delivered
            self.sent = sent
            self.partiallyDelivered = partiallyDelivered
            self.receipt = receipt
            self.targetProcessIdentifier = targetProcessIdentifier
                ?? deliveryAttribution?.targetProcessIdentifier
                ?? receipt?.targetProcessIdentifier
            self.targetBundleIdentifier = targetBundleIdentifier
                ?? deliveryAttribution?.targetBundleIdentifier
                ?? receipt?.targetBundleIdentifier
        }
    }

    private static let accessibilityPreviouslyGrantedKey = "accessibilityPreviouslyGranted"

    /// What an untrusted delivery attempt should do about it.
    struct AccessibilityTrustDecision: Equatable {
        let failure: DeliveryFailure
        /// Whether to raise the system Accessibility sheet. At most once per
        /// launch — a user who dismissed it once should not get a sheet per
        /// dictation. The copied-to-clipboard fallback toast carries the
        /// remediation copy for every later attempt.
        let presentsSystemPrompt: Bool
    }

    /// Pure policy so the prompt-once rule is testable without touching AX.
    static func accessibilityTrustDecision(
        previouslyGranted: Bool,
        hasPromptedThisLaunch: Bool
    ) -> AccessibilityTrustDecision {
        AccessibilityTrustDecision(
            // A grant that used to exist and no longer does means macOS
            // invalidated it (code signature changed across an app update);
            // that needs different remediation copy than a first-time denial.
            failure: previouslyGranted ? .accessibilityPermissionStale : .accessibilityPermissionRequired,
            presentsSystemPrompt: !hasPromptedThisLaunch
        )
    }

    private enum DeliveryMethod {
        case accessibility
        case directTyping
        case pasteShortcut
    }

    struct DiagnosticSnapshot: Equatable {
        let accessibilityTrusted: Bool
        let secureInputActive: Bool
        let blockingModifierFlagsRawValue: UInt64
        let frontmostApplicationName: String?
        let frontmostBundleID: String?

        var hasBlockingModifierFlags: Bool {
            blockingModifierFlagsRawValue != 0
        }
    }

    private enum CandidateRelation {
        case focused
        case descendant(depth: Int)
        case ancestor(depth: Int)
    }

    private struct TextInputSnapshot {
        let element: AXUIElement
        let value: String
        let selectedRange: CFRange?
        let targetFingerprint: ContextTargetFingerprint?
    }

    private struct TextInputCandidate {
        let element: AXUIElement
        let relation: CandidateRelation
        let role: String?
        let subrole: String?
        let value: String
        let placeholderValue: String?
        let selectedRange: CFRange?
        let isValueSettable: Bool

        var valueMatchesPlaceholder: Bool {
            guard let placeholderValue else { return false }
            return Self.normalize(value) == Self.normalize(placeholderValue)
        }

        var insertionBaseValue: String {
            valueMatchesPlaceholder ? "" : value
        }

        var insertionSelectedRange: CFRange? {
            valueMatchesPlaceholder ? nil : selectedRange
        }

        var supportsAXValueInsertion: Bool {
            PasteManager.shouldAttemptAXValueInsertion(
                role: role,
                isValueSettable: isValueSettable,
                currentValue: insertionBaseValue,
                placeholderValue: placeholderValue
            )
        }

        var score: Int {
            relationScore + (isValueSettable ? 35 : 0)
                + (selectedRange != nil ? 20 : 0)
                + (!value.isEmpty ? 6 : 0)
                + (valueMatchesPlaceholder ? 8 : 0)
        }

        private var relationScore: Int {
            switch relation {
            case .focused:
                return 300
            case .descendant(let depth):
                return 220 - min(depth, 6) * 20
            case .ancestor(let depth):
                return 160 - min(depth, 6) * 20
            }
        }

        private static func normalize(_ value: String) -> String {
            value
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private struct AXInsertionAttempt {
        let baselineSnapshot: TextInputSnapshot?
        let usedAXInsertion: Bool
    }

    private struct CapturedDeliveryEvidence {
        let receipt: DeliveryReceipt?
        let attribution: DeliveryAttribution?
        let targetObservedSettledText: String?
    }

    static let shared = PasteManager()

    // Transient pasteboard type — clipboard history managers ignore entries with this type
    static let transientType = NSPasteboard.PasteboardType("de.petermaurer.TransientPasteboardType")
    private static let editorBundleIDs: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed",
        "com.barebones.bbedit",
    ]
    private static let modifierFlagsBlockingSyntheticInput: CGEventFlags = [
        .maskCommand,
        .maskShift,
        .maskAlternate,
        .maskControl,
        .maskSecondaryFn,
    ]
    private let clipboardRestoreDelay: Duration = .milliseconds(300)
    private let targetActivationDelay: Duration = .milliseconds(250)
    private(set) var lastDeliveryFailure: DeliveryFailure?

    /// Set once the system Accessibility sheet has been raised in this launch.
    /// Not persisted: a relaunch is a fresh chance for the user to say yes.
    private var hasPromptedForAccessibility = false

    /// True when the last delivery posted Cmd+V successfully but AX
    /// verification could not confirm it, and the paste was trusted anyway.
    /// Surfaced in analytics so the trust decision stays measurable.
    private(set) var lastDeliveryVerificationDowngraded = false

    private var lastInsertion: SmartInsertionSpacing.LastDelivery?

    var hasAccessibilityPermission: Bool {
        let trusted = AXIsProcessTrusted()
        if trusted {
            UserDefaults.standard.set(true, forKey: Self.accessibilityPreviouslyGrantedKey)
        }
        return trusted
    }

    /// Reads the current value of the focused text input in the given app via AX.
    func focusedFieldContent(
        for app: NSRunningApplication?,
        windowTitle: String? = nil,
        browserURL: String? = nil
    ) -> String? {
        guard let app else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = copyElementAttribute(axApp, kAXFocusedUIElementAttribute as CFString) else {
            return nil
        }
        guard let value = copyStringAttribute(focused, kAXValueAttribute as CFString) else {
            return nil
        }

        let sanitized = AccessibilityPlaceholderFilter.sanitizeFocusedFieldValue(
            value,
            bundleID: app.bundleIdentifier,
            windowTitle: windowTitle,
            browserURL: browserURL,
            placeholderValue: copyStringAttribute(focused, kAXPlaceholderValueAttribute as CFString)
        )
        return sanitized.isEmpty ? nil : sanitized
    }

    func focusedFieldContext(for app: NSRunningApplication?) -> EmailFocusedFieldContext? {
        guard let app else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = copyElementAttribute(axApp, kAXFocusedUIElementAttribute as CFString) else {
            return nil
        }

        return EmailFocusedFieldContext(
            role: copyStringAttribute(focused, kAXRoleAttribute as CFString),
            subrole: copyStringAttribute(focused, kAXSubroleAttribute as CFString),
            title: copyStringAttribute(focused, kAXTitleAttribute as CFString),
            placeholderValue: copyStringAttribute(focused, kAXPlaceholderValueAttribute as CFString),
            identifier: copyStringAttribute(focused, kAXIdentifierAttribute as CFString),
            description: copyStringAttribute(focused, kAXDescriptionAttribute as CFString),
            help: copyStringAttribute(focused, kAXHelpAttribute as CFString)
        )
    }

    static func shouldAttemptAXValueInsertion(
        role: String?,
        isValueSettable: Bool,
        currentValue: String,
        placeholderValue: String? = nil
    ) -> Bool {
        if isValueSettable {
            return true
        }

        // Placeholder-backed web editors can report a writable-looking AX text
        // area while still relying on DOM input events to dismiss the visual
        // placeholder. AXValue mutation there leaves the placeholder drawn over
        // the inserted text, so fall back to Cmd+V.
        guard role == kAXTextAreaRole else {
            return false
        }

        if let placeholderValue,
           !normalizeAXValue(placeholderValue).isEmpty {
            return false
        }

        return normalizeAXValue(currentValue).isEmpty
    }

    static func shouldRestoreSelectionRangeForKeyboardDelivery(
        containsMarkdownLinks: Bool,
        bypassesAXValueInsertion: Bool,
        selectedRange: SelectionRange?
    ) -> Bool {
        guard let selectedRange, selectedRange.length > 0 else {
            return false
        }

        // AX-bypass targets have slow/unreliable trees — re-setting the
        // selection via tree walk stalls paste. Trust the original selection.
        return containsMarkdownLinks && !bypassesAXValueInsertion
    }

    static func shouldCaptureVerificationSnapshot(
        bypassesAXValueInsertion: Bool,
        requiresVerifiedKeyboardDelivery: Bool,
        isSelfTargeting: Bool
    ) -> Bool {
        guard !isSelfTargeting else { return false }
        return !bypassesAXValueInsertion || requiresVerifiedKeyboardDelivery
    }

    static func shouldCaptureCorrectionReceiptSnapshot(
        bypassesCorrectionReadback: Bool,
        isSelfTargeting: Bool
    ) -> Bool {
        !isSelfTargeting && !bypassesCorrectionReadback
    }

    static func shouldIssueCorrectionReceipt(
        baselineValue: String,
        postDeliveryValue: String
    ) -> Bool {
        postDeliveryValue != baselineValue
    }

    static func shouldAttemptAccessibilityDelivery(
        deliveryMode: PasteDeliveryMode,
        bypassesAXValueInsertion: Bool,
        containsMarkdownLinks: Bool
    ) -> Bool {
        switch deliveryMode {
        case .automatic:
            return !bypassesAXValueInsertion && !containsMarkdownLinks
        case .accessibility:
            return true
        case .clipboard, .directTyping:
            return false
        }
    }

    static func shouldUseDirectTyping(
        deliveryMode: PasteDeliveryMode,
        targetPrefersDirectTyping: Bool,
        containsMarkdownLinks: Bool
    ) -> Bool {
        switch deliveryMode {
        case .automatic:
            return !containsMarkdownLinks && targetPrefersDirectTyping
        case .directTyping:
            return true
        case .accessibility, .clipboard:
            return false
        }
    }

    static func blockingSyntheticInputModifierFlags(from flags: CGEventFlags) -> CGEventFlags {
        flags.intersection(modifierFlagsBlockingSyntheticInput)
    }

    static func syntheticInputTargetMatches(
        expectedProcessIdentifier: pid_t?,
        frontmostProcessIdentifier: pid_t?
    ) -> Bool {
        guard let expectedProcessIdentifier else {
            return frontmostProcessIdentifier != nil
        }
        return frontmostProcessIdentifier == expectedProcessIdentifier
    }

    private static func normalizeAXValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Paste

    @MainActor
    func paste(text: String) async -> Bool {
        let deliveryAttemptID = UUID()
        let outcome = await pasteWithOutcome(
            text: text,
            deliveryAttemptID: deliveryAttemptID,
            restoreClipboard: true,
            autoSend: false,
            captureReceipt: false,
            targetApplication: nil,
            windowTitle: nil,
            browserURL: nil,
            deliveryMode: .automatic
        )
        return outcome.delivered
    }

    @MainActor
    func deliver(
        text: String,
        copyToClipboard: Bool,
        autoPaste: Bool,
        autoSend: Bool,
        targetApplication: NSRunningApplication?,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        selectedRange: SelectionRange? = nil,
        deliveryMode: PasteDeliveryMode = .automatic
    ) async -> Bool {
        let outcome = await deliverWithOutcome(
            text: text,
            copyToClipboard: copyToClipboard,
            autoPaste: autoPaste,
            autoSend: autoSend,
            captureReceipt: false,
            targetApplication: targetApplication,
            windowTitle: windowTitle,
            browserURL: browserURL,
            selectedRange: selectedRange,
            deliveryMode: deliveryMode
        )
        return outcome.delivered
    }

    /// Delivers text while returning target-observed evidence suitable for
    /// correction learning. Existing callers can continue using `deliver`,
    /// which remains a Bool-returning compatibility wrapper.
    @MainActor
    func deliverWithOutcome(
        text: String,
        copyToClipboard: Bool,
        autoPaste: Bool,
        autoSend: Bool,
        captureReceipt: Bool = true,
        targetApplication: NSRunningApplication?,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        selectedRange: SelectionRange? = nil,
        deliveryMode: PasteDeliveryMode = .automatic
    ) async -> DeliveryOutcome {
        let deliveryAttemptID = UUID()
        guard !Task.isCancelled else {
            return DeliveryOutcome(
                delivered: false,
                receipt: nil,
                deliveryAttemptID: deliveryAttemptID,
                requestedText: text
            )
        }
        guard !text.isEmpty else {
            return DeliveryOutcome(
                delivered: true,
                receipt: nil,
                deliveryAttemptID: deliveryAttemptID,
                requestedText: text,
                effectiveInsertedText: autoPaste ? text : nil
            )
        }
        guard autoPaste || copyToClipboard else {
            return DeliveryOutcome(
                delivered: true,
                receipt: nil,
                deliveryAttemptID: deliveryAttemptID,
                requestedText: text
            )
        }

        if autoPaste {
            return await pasteWithOutcome(
                text: text,
                deliveryAttemptID: deliveryAttemptID,
                restoreClipboard: !copyToClipboard,
                autoSend: autoSend,
                captureReceipt: captureReceipt && !autoSend,
                targetApplication: targetApplication,
                windowTitle: windowTitle,
                browserURL: browserURL,
                selectedRange: selectedRange,
                deliveryMode: deliveryMode
            )
        }

        return DeliveryOutcome(
            delivered: copy(text: text),
            receipt: nil,
            deliveryAttemptID: deliveryAttemptID,
            requestedText: text
        )
    }

    @MainActor
    func diagnosticSnapshot() -> DiagnosticSnapshot {
        let frontmost = frontmostApplication()
        return DiagnosticSnapshot(
            accessibilityTrusted: AXIsProcessTrusted(),
            secureInputActive: isSecureInputActive(),
            blockingModifierFlagsRawValue: Self.blockingSyntheticInputModifierFlags(
                from: CGEventSource.flagsState(.combinedSessionState)
            ).rawValue,
            frontmostApplicationName: frontmost?.localizedName,
            frontmostBundleID: frontmost?.bundleIdentifier
        )
    }

    @MainActor
    func copy(text: String) -> Bool {
        write(text: text, to: NSPasteboard.general, transient: false)
    }

    @MainActor
    func copyIfEnabled(text: String, isEnabled: Bool) -> Bool {
        guard isEnabled else { return false }
        return copy(text: text)
    }

    @MainActor
    func captureSelectedTextViaCopyShortcut(
        targetApplication: NSRunningApplication?,
        windowTitle: String? = nil,
        browserURL: String? = nil
    ) async -> String? {
        guard let resolvedTargetApplication = resolveTargetApplication(preferred: targetApplication) else {
            return nil
        }

        if !isFrontmost(resolvedTargetApplication) {
            _ = resolvedTargetApplication.activate(options: [.activateAllWindows])
            try? await Task.sleep(for: targetActivationDelay)
            guard isFrontmost(resolvedTargetApplication) else {
                debugLog("Target app failed to become frontmost before copy-shortcut selection capture")
                return nil
            }
        }

        guard ensureAccessibilityForInput() else {
            debugLog("Accessibility permission missing for copy-shortcut selection capture")
            return nil
        }

        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        let initialChangeCount = pasteboard.changeCount
        guard await simulateCmdC(expectedTargetApplication: resolvedTargetApplication) else {
            return nil
        }

        let targetProfile = TextInputTargetProfile(
            bundleID: resolvedTargetApplication.bundleIdentifier,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
        try? await Task.sleep(for: selectionCopyDelay(for: targetProfile))

        let copiedText = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedChangeCount = pasteboard.changeCount
        restorePasteboard(pasteboard, snapshot: snapshot)

        guard updatedChangeCount != initialChangeCount,
              let copiedText,
              !copiedText.isEmpty else {
            return nil
        }

        return copiedText
    }

    @MainActor
    func sendReturn(
        expectedTargetApplication: NSRunningApplication? = nil
    ) async -> Bool {
        guard !isSecureInputActive() else {
            lastDeliveryFailure = .secureInputActive
            return false
        }
        guard syntheticInputTargetIsCurrent(expectedTargetApplication) else {
            lastDeliveryFailure = .targetActivationFailed
            return false
        }

        await waitForSyntheticInputModifiersToSettle()
        guard !Task.isCancelled else { return false }
        guard syntheticInputTargetIsCurrent(expectedTargetApplication) else {
            lastDeliveryFailure = .targetActivationFailed
            return false
        }
        guard !isSecureInputActive() else {
            lastDeliveryFailure = .secureInputActive
            return false
        }

        let src = Self.syntheticKeyboardEventSource()
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)
        else { return false }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    @MainActor
    private func pasteWithOutcome(
        text: String,
        deliveryAttemptID: UUID,
        restoreClipboard: Bool,
        autoSend: Bool,
        captureReceipt: Bool,
        targetApplication: NSRunningApplication?,
        windowTitle: String?,
        browserURL: String?,
        selectedRange: SelectionRange? = nil,
        deliveryMode: PasteDeliveryMode
    ) async -> DeliveryOutcome {
        guard !Task.isCancelled else {
            return DeliveryOutcome(
                delivered: false,
                receipt: nil,
                deliveryAttemptID: deliveryAttemptID,
                requestedText: text
            )
        }
        guard !text.isEmpty else {
            return DeliveryOutcome(
                delivered: true,
                receipt: nil,
                deliveryAttemptID: deliveryAttemptID,
                requestedText: text,
                effectiveInsertedText: text
            )
        }
        lastDeliveryFailure = nil
        lastDeliveryVerificationDowngraded = false

        let resolvedTargetApplication = resolveTargetApplication(preferred: targetApplication)
        let containsMarkdownLinks = Self.containsMarkdownLinks(text)

        if let resolvedTargetApplication,
           !isFrontmost(resolvedTargetApplication) {
            _ = resolvedTargetApplication.activate(options: [.activateAllWindows])
            try? await Task.sleep(for: targetActivationDelay)

            guard isFrontmost(resolvedTargetApplication) else {
                debugLog("Target app failed to become frontmost before paste")
                lastDeliveryFailure = .targetActivationFailed
                return DeliveryOutcome(
                    delivered: false,
                    receipt: nil,
                    deliveryAttemptID: deliveryAttemptID,
                    requestedText: text
                )
            }
        }

        guard !Task.isCancelled else {
            return DeliveryOutcome(
                delivered: false,
                receipt: nil,
                deliveryAttemptID: deliveryAttemptID,
                requestedText: text
            )
        }

        guard ensureAccessibilityForInput() else {
            debugLog("Accessibility permission missing for text delivery (stale: \(lastDeliveryFailure == .accessibilityPermissionStale))")
            return DeliveryOutcome(
                delivered: false,
                receipt: nil,
                deliveryAttemptID: deliveryAttemptID,
                requestedText: text
            )
        }

        let bundleID = resolvedTargetApplication?.bundleIdentifier
        let targetProfile = TextInputTargetProfile(
            bundleID: bundleID,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
        let isCodexTarget = targetProfile.kind == .codexApp
        let requiresVerifiedKeyboardDelivery = targetProfile.requiresVerifiedKeyboardDelivery

        let isSelfTargeting = resolvedTargetApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let bypassesAXValueInsertion = deliveryMode == .accessibility
            ? false
            : targetProfile.bypassesAXValueInsertion || isSelfTargeting
        let restoreCFRange = selectedRange.map { CFRange(location: $0.location, length: $0.length) }

        if isCodexTarget {
            debugLog(
                "[CodexDeliveryDebug] prepare bundleID=\(bundleID ?? "nil") selectedRange=\(describe(selectedRange)) " +
                "containsMarkdownLinks=\(containsMarkdownLinks) bypassAX=\(bypassesAXValueInsertion) " +
                "verifyKeyboard=\(requiresVerifiedKeyboardDelivery) selfTarget=\(isSelfTargeting)"
            )
        }

        if Self.shouldRestoreSelectionRangeForKeyboardDelivery(
            containsMarkdownLinks: containsMarkdownLinks,
            bypassesAXValueInsertion: bypassesAXValueInsertion,
            selectedRange: selectedRange
        ) {
            let restored = restoreSelectionRangeForKeyboardDelivery(
                restoreCFRange,
                targetApplication: resolvedTargetApplication
            )
            if isCodexTarget {
                debugLog("[CodexDeliveryDebug] prePasteSelectionRestore restored=\(restored)")
            }
        } else if isCodexTarget {
            debugLog("[CodexDeliveryDebug] prePasteSelectionRestore skipped")
        }

        // Smart spacing: prepend a space when the cursor sits directly after
        // non-whitespace text (e.g. consecutive dictation pastes).
        // Also lowercases the first letter when continuing mid-sentence.
        // Skip for selection transforms and AX-bypassed targets.
        let smartSpacedText = selectedRange == nil && !bypassesAXValueInsertion
            ? applySmartSpacing(
                to: text,
                for: resolvedTargetApplication,
                bundleID: bundleID,
                windowTitle: windowTitle,
                browserURL: browserURL
            )
            : text
        let plainText = Self.effectiveInsertedPlainText(afterSmartSpacing: smartSpacedText)
        // Skip snapshot for AX-unreliable targets unless the profile
        // explicitly requires verified keyboard delivery.
        let verificationSnapshot: TextInputSnapshot? = Self.shouldCaptureVerificationSnapshot(
            bypassesAXValueInsertion: bypassesAXValueInsertion,
            requiresVerifiedKeyboardDelivery: requiresVerifiedKeyboardDelivery,
            isSelfTargeting: isSelfTargeting
        )
            ? focusedTextSnapshot(
                targetApplication: resolvedTargetApplication,
                bundleID: bundleID,
                windowTitle: windowTitle,
                browserURL: browserURL
            )
            : nil
        // Some web editors deliberately bypass AX writes but still expose a
        // stable read-only element. Capture that exact element for correction
        // attribution without making delivery verification mandatory.
        let correctionReceiptSnapshot = captureReceipt ? (verificationSnapshot ?? (
            Self.shouldCaptureCorrectionReceiptSnapshot(
                bypassesCorrectionReadback: targetProfile.bypassesCorrectionReadback,
                isSelfTargeting: isSelfTargeting
            )
                ? focusedTextSnapshot(
                    targetApplication: resolvedTargetApplication,
                    bundleID: bundleID,
                    windowTitle: windowTitle,
                    browserURL: browserURL
                )
                : nil
        )) : nil
        let axInsertionAttempt: AXInsertionAttempt
        let shouldAttemptAXInsertion = Self.shouldAttemptAccessibilityDelivery(
            deliveryMode: deliveryMode,
            bypassesAXValueInsertion: bypassesAXValueInsertion,
            containsMarkdownLinks: containsMarkdownLinks
        )

        guard !Task.isCancelled else {
            return DeliveryOutcome(
                delivered: false,
                receipt: nil,
                deliveryAttemptID: deliveryAttemptID,
                requestedText: text
            )
        }
        if !shouldAttemptAXInsertion {
            if isCodexTarget {
                debugLog(
                    "[CodexDeliveryDebug] skippingAXInsertion reason=" +
                    (bypassesAXValueInsertion ? "bypass" : "delivery_mode")
                )
            }
            axInsertionAttempt = AXInsertionAttempt(baselineSnapshot: nil, usedAXInsertion: false)
        } else {
            axInsertionAttempt = insertIntoFocusedTextInput(
                plainText,
                targetApplication: resolvedTargetApplication,
                restoreSelectedRange: restoreCFRange
            )
            if isCodexTarget {
                debugLog("[CodexDeliveryDebug] attemptedAXInsertion usedAX=\(axInsertionAttempt.usedAXInsertion)")
            }
        }

        let prefersDirectTyping = Self.shouldUseDirectTyping(
            deliveryMode: deliveryMode,
            targetPrefersDirectTyping: targetProfile.prefersDirectTyping,
            containsMarkdownLinks: containsMarkdownLinks
        )
        if isCodexTarget {
            let baselineKind = axInsertionAttempt.baselineSnapshot != nil || verificationSnapshot != nil ? "present" : "missing"
            let method = prefersDirectTyping ? "directTyping" : "pasteShortcut"
            debugLog("[CodexDeliveryDebug] keyboardDelivery method=\(method) baselineSnapshot=\(baselineKind)")
        }
        let success = await deliverText(
            text: plainText,
            pasteText: smartSpacedText,
            bundleID: bundleID,
            windowTitle: windowTitle,
            browserURL: browserURL,
            targetApplication: resolvedTargetApplication,
            baselineSnapshot: axInsertionAttempt.baselineSnapshot ?? verificationSnapshot,
            usedAXInsertion: axInsertionAttempt.usedAXInsertion,
            prefersDirectTyping: prefersDirectTyping,
            requiresVerifiedDelivery: requiresVerifiedKeyboardDelivery,
            restoreClipboard: restoreClipboard,
            deliveryMode: deliveryMode
        )

        let deliveryEvidence = success ? captureDeliveryEvidence(
            baselineSnapshot: axInsertionAttempt.baselineSnapshot
                ?? correctionReceiptSnapshot
                ?? verificationSnapshot,
            targetApplication: resolvedTargetApplication,
            bundleID: bundleID,
            windowTitle: windowTitle,
            browserURL: browserURL,
            retainReceipt: captureReceipt
        ) : nil

        if success {
            // Use plainText (no markdown-link syntax) since that's what the
            // cursor will read back from AX on the next paste.
            lastInsertion = SmartInsertionSpacing.LastDelivery(
                deliveredText: plainText,
                target: SmartInsertionSpacing.Target(
                    bundleID: bundleID,
                    windowTitle: windowTitle,
                    browserURL: browserURL
                )
            )
        }

        if isCodexTarget {
            debugLog("[CodexDeliveryDebug] deliveryResult success=\(success)")
        }

        var sent = false
        if success, autoSend {
            try? await Task.sleep(for: sendDelay(for: targetProfile))
            if !Task.isCancelled {
                sent = await sendReturn(expectedTargetApplication: resolvedTargetApplication)
            }
        }

        return DeliveryOutcome(
            delivered: success,
            sent: sent,
            partiallyDelivered: lastDeliveryFailure == .partialDelivery,
            receipt: deliveryEvidence?.receipt,
            targetProcessIdentifier: resolvedTargetApplication?.processIdentifier,
            targetBundleIdentifier: resolvedTargetApplication?.bundleIdentifier,
            deliveryAttemptID: deliveryAttemptID,
            requestedText: text,
            effectiveInsertedText: success ? plainText : nil,
            targetObservedSettledText: deliveryEvidence?.targetObservedSettledText,
            deliveryAttribution: deliveryEvidence?.attribution
        )
    }

    // MARK: - Fallback: direct Unicode injection

    /// Injects text character by character using CGEventKeyboardSetUnicodeString.
    /// Slower but works in apps that intercept Cmd+V.
    @MainActor
    func typeText(
        _ text: String,
        bundleID: String? = nil,
        targetApplication: NSRunningApplication? = nil
    ) async -> Bool {
        guard !isSecureInputActive() else {
            lastDeliveryFailure = .secureInputActive
            return false
        }

        await waitForSyntheticInputModifiersToSettle()
        guard !Task.isCancelled else { return false }
        guard syntheticInputTargetIsCurrent(targetApplication) else {
            lastDeliveryFailure = .targetActivationFailed
            return false
        }

        let src = Self.syntheticKeyboardEventSource()
        let chunks = text.chunked(into: typingChunkSize(for: bundleID))
        let events: [(CGEvent, CGEvent)] = chunks.compactMap { chunk in
            let chars = Array(chunk.utf16)
            guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            else {
                return nil
            }

            keyDown.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            return (keyDown, keyUp)
        }
        guard events.count == chunks.count else {
            debugLog("CGEvent creation failed for Unicode typing (source \(src == nil ? "unavailable" : "ok"))")
            return false
        }

        guard let firstEvent = events.first else { return true }
        guard !Task.isCancelled else { return false }
        guard syntheticInputTargetIsCurrent(targetApplication) else {
            lastDeliveryFailure = .targetActivationFailed
            return false
        }
        guard !isSecureInputActive() else {
            lastDeliveryFailure = .secureInputActive
            return false
        }

        // The first chunk is the commit point and is posted synchronously. Only
        // after that irreversible event do we shield the remainder from caller
        // cancellation so pacing cannot collapse and make the target drop text.
        firstEvent.0.post(tap: .cghidEventTap)
        firstEvent.1.post(tap: .cghidEventTap)
        let remainingEvents = Array(events.dropFirst())
        guard !remainingEvents.isEmpty else { return true }

        let deliveryTask = Task { @MainActor [remainingEvents] in
            let interChunkDelay = self.typingInterChunkDelay(for: bundleID)
            try? await Task.sleep(for: interChunkDelay)
            for (index, eventPair) in remainingEvents.enumerated() {
                guard self.syntheticInputTargetIsCurrent(targetApplication),
                      !self.isSecureInputActive() else {
                    self.lastDeliveryFailure = .partialDelivery
                    return false
                }

                eventPair.0.post(tap: .cghidEventTap)
                eventPair.1.post(tap: .cghidEventTap)
                if index < remainingEvents.index(before: remainingEvents.endIndex) {
                    try? await Task.sleep(for: interChunkDelay)
                }
            }
            return true
        }
        return await deliveryTask.value
    }

    private func insertIntoFocusedTextInput(
        _ text: String,
        targetApplication: NSRunningApplication?,
        restoreSelectedRange: CFRange? = nil
    ) -> AXInsertionAttempt {
        guard let targetApplication else {
            return AXInsertionAttempt(baselineSnapshot: nil, usedAXInsertion: false)
        }

        let axApp = AXUIElementCreateApplication(targetApplication.processIdentifier)
        guard let focusedElement = copyElementAttribute(axApp, kAXFocusedUIElementAttribute as CFString) else {
            debugLog("No focused AX element for \(targetApplication.bundleIdentifier ?? targetApplication.localizedName ?? "unknown")")
            return AXInsertionAttempt(baselineSnapshot: nil, usedAXInsertion: false)
        }

        let candidates = insertionCandidates(startingAt: focusedElement)
        for candidate in candidates {
            // A selection transform restores the dictation-start range immediately
            // before insertion. Anchor the receipt to that effective range rather
            // than the cursor position observed after ASR completed.
            let baselineSnapshot = textSnapshot(for: candidate).map { snapshot in
                TextInputSnapshot(
                    element: snapshot.element,
                    value: snapshot.value,
                    selectedRange: restoreSelectedRange ?? snapshot.selectedRange,
                    targetFingerprint: targetFingerprint(
                        for: snapshot.element,
                        selectedRange: restoreSelectedRange ?? snapshot.selectedRange
                    )
                )
            }
            if tryInsertText(text, into: candidate, focusedElement: focusedElement, restoreSelectedRange: restoreSelectedRange) {
                debugLog("Inserted text via AX into \(describe(candidate))")
                return AXInsertionAttempt(
                    baselineSnapshot: baselineSnapshot,
                    usedAXInsertion: true
                )
            }
        }

        debugLog("AX insertion failed for all candidates in \(targetApplication.bundleIdentifier ?? targetApplication.localizedName ?? "unknown")")
        return AXInsertionAttempt(baselineSnapshot: nil, usedAXInsertion: false)
    }

    private func tryInsertText(
        _ text: String,
        into candidate: TextInputCandidate,
        focusedElement: AXUIElement,
        restoreSelectedRange: CFRange? = nil
    ) -> Bool {
        guard candidate.supportsAXValueInsertion else {
            return false
        }

        // If a selection range was captured at dictation start, restore it now so
        // the transform result replaces the original selected text rather than
        // inserting at whatever cursor position exists after the processing delay.
        if var range = restoreSelectedRange,
           let rangeValue = AXValueCreate(.cfRange, &range) {
            _ = AXUIElementSetAttributeValue(
                candidate.element,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
        }

        // Prefer kAXSelectedTextAttribute — replaces the current selection (or
        // inserts at cursor when there is no selection) without touching the full
        // field value. This lets the app own cursor placement, which avoids the
        // common failure mode where setting kAXValueAttribute resets the cursor
        // to position 0.
        if isAttributeSettable(candidate.element, attribute: kAXSelectedTextAttribute as CFString) {
            let setResult = AXUIElementSetAttributeValue(
                candidate.element,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            )
            if setResult == .success {
                debugLog("Inserted text via AX selectedText into \(describe(candidate))")
                return true
            }
            debugLog("AX selectedText set failed for \(describe(candidate)) — falling back to value replacement")
        }

        // Fall back: reconstruct the full string and set kAXValueAttribute, then
        // manually reposition the cursor.
        let replacement = applyingInsertion(
            to: candidate.insertionBaseValue,
            selectedRange: restoreSelectedRange ?? candidate.insertionSelectedRange,
            insertedText: text
        )

        let setResult = AXUIElementSetAttributeValue(
            candidate.element,
            kAXValueAttribute as CFString,
            replacement.text as CFTypeRef
        )
        guard setResult == .success else {
            debugLog("AX set value failed for \(describe(candidate)) with result \(setResult.rawValue)")
            return false
        }

        setInsertionPoint(
            in: candidate.element,
            utf16Location: replacement.cursorLocation,
            documentLength: replacement.text.utf16.count
        )
        if CFHash(candidate.element) != CFHash(focusedElement) {
            setInsertionPoint(
                in: focusedElement,
                utf16Location: replacement.cursorLocation,
                documentLength: replacement.text.utf16.count
            )
        }
        return true
    }

    private func restoreSelectionRangeForKeyboardDelivery(
        _ selectionRange: CFRange?,
        targetApplication: NSRunningApplication?
    ) -> Bool {
        guard let selectionRange,
              selectionRange.length > 0,
              let targetApplication else {
            return false
        }

        let axApp = AXUIElementCreateApplication(targetApplication.processIdentifier)
        let targets: [AXUIElement]
        if let focusedElement = copyElementAttribute(axApp, kAXFocusedUIElementAttribute as CFString) {
            targets = [focusedElement] + insertionCandidates(startingAt: focusedElement).map(\.element)
        } else {
            debugLog("No focused AX element available; falling back to window-tree selection restore targets")
            targets = selectionRestoreTargetsFromWindows(axApp: axApp)
        }

        var visited = Set<CFHashCode>()

        for target in targets {
            let hash = CFHash(target)
            guard visited.insert(hash).inserted else { continue }
            guard isAttributeSettable(target, attribute: kAXSelectedTextRangeAttribute as CFString) else {
                continue
            }

            var range = selectionRange
            guard let rangeValue = AXValueCreate(.cfRange, &range) else {
                continue
            }

            if AXUIElementSetAttributeValue(
                target,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            ) == .success {
                debugLog("Restored selection range via AX before keyboard delivery")
                return true
            }
        }

        debugLog("Failed to restore selection range via AX before keyboard delivery")
        return false
    }

    private func selectionRestoreTargetsFromWindows(axApp: AXUIElement) -> [AXUIElement] {
        var targets: [AXUIElement] = []
        var visited = Set<CFHashCode>()

        func append(_ element: AXUIElement, depth: Int, maxDepth: Int) {
            guard depth <= maxDepth else { return }
            let hash = CFHash(element)
            guard visited.insert(hash).inserted else { return }
            targets.append(element)

            for child in copyElementArrayAttribute(element, kAXChildrenAttribute as CFString).prefix(24) {
                append(child, depth: depth + 1, maxDepth: maxDepth)
            }
        }

        for window in copyElementArrayAttribute(axApp, kAXWindowsAttribute as CFString).prefix(4) {
            append(window, depth: 0, maxDepth: 6)
        }

        return targets
    }

    private func isDirectTextInputRole(role: String?, subrole: String?) -> Bool {
        guard role == kAXTextFieldRole
            || role == kAXTextAreaRole
            || role == kAXComboBoxRole
            || subrole == "AXSearchField"
        else {
            return false
        }

        return true
    }

    private func setInsertionPoint(in element: AXUIElement, utf16Location: Int, documentLength: Int) {
        var selectedRange = CFRange(location: utf16Location, length: 0)
        guard let selectionValue = AXValueCreate(.cfRange, &selectedRange) else {
            return
        }

        _ = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            selectionValue
        )

        let clampedDocumentLength = max(0, documentLength)
        guard clampedDocumentLength > 0 else { return }

        let revealLocation = min(
            max(0, utf16Location - 1),
            max(0, clampedDocumentLength - 1)
        )
        var visibleRange = CFRange(
            location: revealLocation,
            length: min(1, clampedDocumentLength - revealLocation)
        )
        guard let visibleRangeValue = AXValueCreate(.cfRange, &visibleRange) else {
            return
        }

        _ = AXUIElementSetAttributeValue(
            element,
            kAXVisibleCharacterRangeAttribute as CFString,
            visibleRangeValue
        )
    }

    // MARK: - CGEvent Cmd+V

    /// Returns `true` when accessibility is granted, `false` otherwise.
    /// Sets `lastDeliveryFailure` to distinguish first-time denial from a
    /// stale grant (macOS invalidated the permission after an app update
    /// because the code signature changed).
    private func ensureAccessibilityForInput() -> Bool {
        if AXIsProcessTrusted() {
            UserDefaults.standard.set(true, forKey: Self.accessibilityPreviouslyGrantedKey)
            return true
        }

        let decision = Self.accessibilityTrustDecision(
            previouslyGranted: UserDefaults.standard.bool(forKey: Self.accessibilityPreviouslyGrantedKey),
            hasPromptedThisLaunch: hasPromptedForAccessibility
        )
        lastDeliveryFailure = decision.failure

        // Re-run the trusted-with-options path once per launch so a stale
        // post-update grant still gets a chance to re-arm; after that, check
        // silently rather than throwing a system sheet at every dictation.
        let trusted: Bool
        if decision.presentsSystemPrompt {
            hasPromptedForAccessibility = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
        } else {
            trusted = AXIsProcessTrusted()
        }

        if trusted {
            UserDefaults.standard.set(true, forKey: Self.accessibilityPreviouslyGrantedKey)
            lastDeliveryFailure = nil
        }
        return trusted
    }

    @MainActor
    private func deliverText(
        text: String,
        pasteText: String,
        bundleID: String?,
        windowTitle: String?,
        browserURL: String?,
        targetApplication: NSRunningApplication?,
        baselineSnapshot: TextInputSnapshot?,
        usedAXInsertion: Bool,
        prefersDirectTyping: Bool,
        requiresVerifiedDelivery: Bool,
        restoreClipboard: Bool,
        deliveryMode: PasteDeliveryMode
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        if deliveryMode == .accessibility {
            guard usedAXInsertion else {
                debugLog("Accessibility delivery requested but no writable focused text input was found")
                lastDeliveryFailure = .deliveryUnverified
                return false
            }

            let verified = await verifyDelivery(
                of: text,
                baselineSnapshot: baselineSnapshot,
                targetApplication: targetApplication,
                method: .accessibility,
                requiresVerifiedDelivery: true,
                bundleID: bundleID,
                windowTitle: windowTitle,
                browserURL: browserURL
            )
            if verified {
                return true
            }

            debugLog("Accessibility delivery requested but insertion was unverified")
            lastDeliveryFailure = .deliveryUnverified
            return false
        }

        // If AX insertion already set the value, verify it actually took effect.
        // Only fall through to keyboard delivery if the element value is unchanged
        // (meaning the app ignored the AX set).
        if usedAXInsertion {
            let verified = await verifyDelivery(
                of: text,
                baselineSnapshot: baselineSnapshot,
                targetApplication: targetApplication,
                method: .accessibility,
                requiresVerifiedDelivery: requiresVerifiedDelivery,
                bundleID: bundleID,
                windowTitle: windowTitle,
                browserURL: browserURL
            )
            if verified {
                return true
            }
            debugLog("AX insertion unverified — falling through to keyboard delivery")
        }

        // Apps that prefer character-by-character typing (e.g. apps that
        // intercept Cmd+V for other purposes).
        if prefersDirectTyping {
            debugLog("Using direct typing for target \(bundleID ?? "unknown")")
            let typed = await typeText(
                text,
                bundleID: bundleID,
                targetApplication: targetApplication
            )
            guard typed else { return false }
            guard let baselineSnapshot else {
                if requiresVerifiedDelivery {
                    debugLog("Direct typing posted without verification baseline")
                    lastDeliveryFailure = .deliveryUnverified
                    return false
                }
                guard unverifiedDeliveryStayedOnTarget(targetApplication, bundleID: bundleID, method: "Direct typing") else {
                    lastDeliveryFailure = .deliveryUnverified
                    return false
                }
                return true
            }

            let verified = await verifyDelivery(
                of: text,
                baselineSnapshot: baselineSnapshot,
                targetApplication: targetApplication,
                method: .directTyping,
                requiresVerifiedDelivery: requiresVerifiedDelivery,
                bundleID: bundleID,
                windowTitle: windowTitle,
                browserURL: browserURL
            )
            if verified {
                return true
            }

            debugLog("Direct typing unverified — reporting failure")
            lastDeliveryFailure = .deliveryUnverified
            return false
        }

        // Standard keyboard paste via Cmd+V. Once the events are posted,
        // trust that delivery succeeded — do NOT fall through to typeText,
        // which would cause double-paste in terminals and web apps where
        // AX verification reads the wrong element.
        guard let pasteboardWrite = preparePasteboardForPaste(text: pasteText, restoreClipboard: restoreClipboard) else {
            lastDeliveryFailure = .writeFailed
            return false
        }

        guard !Task.isCancelled else {
            restoreClipboardIfNeeded(after: pasteboardWrite)
            return false
        }
        if await simulateCmdV(expectedTargetApplication: targetApplication) {
            guard let baselineSnapshot else {
                if requiresVerifiedDelivery {
                    debugLog("Cmd+V posted without verification baseline")
                    lastDeliveryFailure = .deliveryUnverified
                    restoreClipboardIfNeeded(after: pasteboardWrite)
                    return false
                }
                guard unverifiedDeliveryStayedOnTarget(targetApplication, bundleID: bundleID, method: "Cmd+V") else {
                    lastDeliveryFailure = .deliveryUnverified
                    restoreClipboardIfNeeded(after: pasteboardWrite)
                    return false
                }
                // Can't verify delivery for AX-bypass targets. Schedule a
                // delayed restore anyway — the changeCount + transient-marker
                // guards in restorePasteboardIfStillOwned prevent stomping on
                // anything the user copies in the interim, and the delay still
                // leaves a short manual-recovery window for a second ⌘V.
                scheduleClipboardRestoreIfNeeded(after: pasteboardWrite)
                return true
            }

            let verified = await verifyDelivery(
                of: text,
                baselineSnapshot: baselineSnapshot,
                targetApplication: targetApplication,
                method: .pasteShortcut,
                requiresVerifiedDelivery: requiresVerifiedDelivery,
                bundleID: bundleID,
                windowTitle: windowTitle,
                browserURL: browserURL
            )
            if verified {
                scheduleClipboardRestoreIfNeeded(after: pasteboardWrite)
                return true
            }

            // Verification is advisory once Cmd+V has posted: Electron and
            // terminal AX trees often never reflect the pasted value, and
            // reporting failure here turns a delivered paste into a "Copied
            // to clipboard" notice and a double-paste hazard. Trust the
            // posted events while the target held the foreground; callers
            // that need proof (selection transforms) still get a failure.
            if !requiresVerifiedDelivery,
               unverifiedDeliveryStayedOnTarget(targetApplication, bundleID: bundleID, method: "Cmd+V") {
                debugLog("Cmd+V unverified but target held foreground — trusting posted paste")
                lastDeliveryVerificationDowngraded = true
                scheduleClipboardRestoreIfNeeded(after: pasteboardWrite)
                return true
            }

            debugLog("Cmd+V unverified — restoring clipboard and reporting failure")
            lastDeliveryFailure = .deliveryUnverified
            restoreClipboardIfNeeded(after: pasteboardWrite)
            return false
        }

        // simulateCmdV failed — either no frontmost target or CGEvent
        // creation failed. Don't fall through to typing when there is
        // no target; restore the clipboard and report failure so the
        // caller can copy to clipboard as a fallback.
        if lastDeliveryFailure == .noFrontmostTarget
            || lastDeliveryFailure == .secureInputActive
            || lastDeliveryFailure == .targetActivationFailed {
            debugLog("Cmd+V unavailable (\(String(describing: lastDeliveryFailure))) — skipping typing fallback")
            restoreClipboardIfNeeded(after: pasteboardWrite)
            return false
        }

        debugLog("Cmd+V failed to post — falling back to Unicode typing")
        let typed = await typeText(
            text,
            bundleID: bundleID,
            targetApplication: targetApplication
        )
        restoreClipboardIfNeeded(after: pasteboardWrite)
        guard typed else { return false }
        guard let baselineSnapshot else {
            if requiresVerifiedDelivery {
                debugLog("Direct typing fallback posted without verification baseline")
                lastDeliveryFailure = .deliveryUnverified
                return false
            }
            guard unverifiedDeliveryStayedOnTarget(targetApplication, bundleID: bundleID, method: "Direct typing fallback") else {
                lastDeliveryFailure = .deliveryUnverified
                return false
            }
            return true
        }

        let verified = await verifyDelivery(
            of: text,
            baselineSnapshot: baselineSnapshot,
            targetApplication: targetApplication,
            method: .directTyping,
            requiresVerifiedDelivery: requiresVerifiedDelivery,
            bundleID: bundleID,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
        if verified {
            return true
        }

        debugLog("Direct typing fallback unverified — reporting failure")
        lastDeliveryFailure = .deliveryUnverified
        return false
    }

    @MainActor
    private func verifyDelivery(
        of text: String,
        baselineSnapshot: TextInputSnapshot?,
        targetApplication: NSRunningApplication?,
        method: DeliveryMethod,
        requiresVerifiedDelivery: Bool,
        bundleID: String?,
        windowTitle: String?,
        browserURL: String?
    ) async -> Bool {
        guard let baselineSnapshot else {
            return true
        }

        // Every caller reaches verification only after an AX mutation or
        // keyboard event has committed. Run the settle delay/read in an
        // independently-owned task so cancellation cannot collapse the delay
        // and misclassify already-delivered text as unchanged.
        let verificationTask = Task { @MainActor in
            try? await Task.sleep(for: verificationDelay(for: method, bundleID: bundleID))

            let currentSnapshot = textSnapshot(
                for: baselineSnapshot.element,
                bundleID: bundleID,
                windowTitle: windowTitle,
                browserURL: browserURL
            )

            guard let currentSnapshot else {
                // Element became unreadable — delivery likely succeeded but the app
                // changed state (e.g. focus shifted, terminal scrolled). Returning false
                // here would trigger a second delivery attempt, causing double-paste.
                if requiresVerifiedDelivery {
                    debugLog("Verification: element unreadable after \(method) — reporting failure")
                    return false
                }
                debugLog("Verification: element unreadable after \(method) — assuming success")
                return true
            }

            let expected = applyingInsertion(
                to: baselineSnapshot.value,
                selectedRange: baselineSnapshot.selectedRange,
                insertedText: text
            )

            if currentSnapshot.value == expected.text {
                return true
            }

            // Only report failure when the value is completely unchanged from
            // baseline — that is the one signal that delivery genuinely did not
            // reach the target element (e.g. the app intercepts Cmd+V for
            // something else).
            if currentSnapshot.value == baselineSnapshot.value {
                debugLog("Verification: value unchanged after \(method) — delivery may have failed")
                return false
            }

            // Value changed but doesn't match expected — the app likely accepted
            // the text and transformed/reformatted it (common in terminals, web
            // apps, rich text editors). Treat as success to avoid double-paste.
            debugLog("Verification: value changed after \(method) — assuming success")
            return true
        }
        return await verificationTask.value
    }

    /// Reads only the element retained by a delivery receipt. Deliberately does
    /// not fall back to whichever field is currently focused: learning from a
    /// different field would turn unrelated user edits into dictation feedback.
    /// Target identity and sensitivity are recomputed on every read rather than
    /// trusting delivery-time state for the entire observation window.
    @MainActor
    func exactReceiptSnapshot(
        for receipt: DeliveryReceipt
    ) -> CorrectionReceiptSnapshot? {
        guard let runningApplication = NSRunningApplication(
            processIdentifier: receipt.targetProcessIdentifier
        ) else {
            return nil
        }
        guard let snapshot = textSnapshot(
            for: receipt.element,
            bundleID: runningApplication.bundleIdentifier,
            windowTitle: receipt.windowTitle,
            browserURL: receipt.browserURL
        ) else {
            return nil
        }

        return CorrectionReceiptSnapshot(
            fullFieldContent: snapshot.value,
            processIdentifier: runningApplication.processIdentifier,
            bundleIdentifier: runningApplication.bundleIdentifier,
            isSensitiveInput: snapshot.targetFingerprint?.isSensitiveInput,
            targetFingerprint: snapshot.targetFingerprint
        )
    }

    private func captureDeliveryEvidence(
        baselineSnapshot: TextInputSnapshot?,
        targetApplication: NSRunningApplication?,
        bundleID: String?,
        windowTitle: String?,
        browserURL: String?,
        retainReceipt: Bool
    ) -> CapturedDeliveryEvidence? {
        guard let baselineSnapshot,
              let targetApplication,
              let postDeliverySnapshot = textSnapshot(
                for: baselineSnapshot.element,
                bundleID: bundleID,
                windowTitle: windowTitle,
                browserURL: browserURL
              )
        else {
            return nil
        }

        // A correction-only snapshot is not delivery verification. If the
        // retained element is unchanged, Cmd+V may have been intercepted and
        // its old selected text must not become false acceptance evidence.
        guard Self.shouldIssueCorrectionReceipt(
            baselineValue: baselineSnapshot.value,
            postDeliveryValue: postDeliverySnapshot.value
        ) else {
            return nil
        }

        let selectedRange = baselineSnapshot.selectedRange.map {
            SelectionRange(location: $0.location, length: $0.length)
        }
        guard let anchoredInsertion = Self.makeUTF16InsertionAnchor(
            baselineValue: baselineSnapshot.value,
            selectedRange: selectedRange,
            postDeliveryValue: postDeliverySnapshot.value
        ), !anchoredInsertion.targetObservedInsertedText.isEmpty else {
            return nil
        }

        let attribution = Self.makeDeliveryAttribution(
            targetProcessIdentifier: targetApplication.processIdentifier,
            targetBundleIdentifier: targetApplication.bundleIdentifier,
            targetFingerprint: baselineSnapshot.targetFingerprint,
            anchor: anchoredInsertion.anchor,
            preDeliveryFieldUTF16Length: (baselineSnapshot.value as NSString).length
        )
        let receipt = retainReceipt ? DeliveryReceipt(
            targetProcessIdentifier: targetApplication.processIdentifier,
            targetBundleIdentifier: targetApplication.bundleIdentifier,
            targetObservedInsertedText: anchoredInsertion.targetObservedInsertedText,
            anchor: anchoredInsertion.anchor,
            element: baselineSnapshot.element,
            windowTitle: windowTitle,
            browserURL: browserURL
        ) : nil

        return CapturedDeliveryEvidence(
            receipt: receipt,
            attribution: attribution,
            targetObservedSettledText: anchoredInsertion.targetObservedInsertedText
        )
    }

    /// Builds the text-free attribution value shared by receipt and no-receipt
    /// correction paths. Invalid or unidentified targets fail closed.
    static func makeDeliveryAttribution(
        targetProcessIdentifier: pid_t?,
        targetBundleIdentifier: String?,
        targetFingerprint: ContextTargetFingerprint?,
        anchor: UTF16InsertionAnchor,
        preDeliveryFieldUTF16Length: Int
    ) -> DeliveryAttribution? {
        guard let targetProcessIdentifier,
              let targetBundleIdentifier,
              !targetBundleIdentifier.isEmpty,
              preDeliveryFieldUTF16Length >= 0,
              anchor.replacedRange.location >= 0,
              anchor.replacedRange.length >= 0,
              anchor.replacedRange.location + anchor.replacedRange.length
                <= preDeliveryFieldUTF16Length else {
            return nil
        }

        return DeliveryAttribution(
            targetProcessIdentifier: targetProcessIdentifier,
            targetBundleIdentifier: targetBundleIdentifier,
            isSensitiveInput: targetFingerprint?.isSensitiveInput,
            targetFingerprint: targetFingerprint,
            anchor: anchor,
            preDeliveryFieldUTF16Length: preDeliveryFieldUTF16Length,
            wholeFieldOwned: anchor.replacedRange.location == 0
                && anchor.replacedRange.length == preDeliveryFieldUTF16Length
        )
    }

    /// Builds an AX-compatible anchor using only strings and UTF-16 ranges.
    /// Returning nil means the target's post-delivery value could not be
    /// explained as one replacement inside the baseline value.
    static func makeUTF16InsertionAnchor(
        baselineValue: String,
        selectedRange: SelectionRange?,
        postDeliveryValue: String
    ) -> (anchor: UTF16InsertionAnchor, targetObservedInsertedText: String)? {
        let baseline = baselineValue as NSString
        let requestedLocation = selectedRange?.location ?? baseline.length
        let location = max(0, min(requestedLocation, baseline.length))
        let requestedLength = selectedRange?.length ?? 0
        let length = max(0, min(requestedLength, baseline.length - location))
        let replacedRange = SelectionRange(location: location, length: length)
        let anchor = UTF16InsertionAnchor(
            replacedRange: replacedRange,
            prefix: baseline.substring(to: location),
            suffix: baseline.substring(from: location + length)
        )

        guard let targetObservedInsertedText = anchoredInsertedRegion(
            in: postDeliveryValue,
            anchor: anchor
        ) else {
            return nil
        }
        return (anchor, targetObservedInsertedText)
    }

    /// Extracts the region between an anchor's exact UTF-16 prefix and suffix.
    /// This function intentionally performs no fuzzy matching.
    static func anchoredInsertedRegion(
        in fieldValue: String,
        anchor: UTF16InsertionAnchor
    ) -> String? {
        let field = fieldValue as NSString
        let prefixLength = anchor.prefixUTF16Length
        let suffixLength = anchor.suffixUTF16Length
        guard field.length >= prefixLength + suffixLength else {
            return nil
        }
        let prefix = field.substring(to: prefixLength)
        let suffix = field.substring(from: field.length - suffixLength)
        guard anchor.matches(prefix: prefix, suffix: suffix) else {
            return nil
        }

        return field.substring(
            with: NSRange(
                location: prefixLength,
                length: field.length - prefixLength - suffixLength
            )
        )
    }

    private func insertionCandidates(startingAt focusedElement: AXUIElement) -> [TextInputCandidate] {
        var candidates: [TextInputCandidate] = []
        var visited = Set<CFHashCode>()

        func append(_ element: AXUIElement, relation: CandidateRelation) {
            let hash = CFHash(element)
            guard !visited.contains(hash) else { return }
            visited.insert(hash)
            guard let candidate = makeTextInputCandidate(element, relation: relation) else {
                return
            }
            candidates.append(candidate)
        }

        append(focusedElement, relation: .focused)
        appendDescendantCandidates(of: focusedElement, depth: 1, maxDepth: 3, into: &candidates, visited: &visited)

        var ancestor: AXUIElement? = focusedElement
        for depth in 1...4 {
            guard let current = ancestor,
                  let parent = copyElementAttribute(current, kAXParentAttribute as CFString) else {
                break
            }
            append(parent, relation: .ancestor(depth: depth))
            ancestor = parent
        }

        let sorted = candidates.sorted { left, right in
            if left.score == right.score {
                return describe(left) < describe(right)
            }
            return left.score > right.score
        }

        debugLog("AX insertion candidates: \(sorted.map(describe).joined(separator: " | "))")
        return sorted
    }

    private func focusedTextSnapshot(
        targetApplication: NSRunningApplication?,
        bundleID: String?,
        windowTitle: String?,
        browserURL: String?
    ) -> TextInputSnapshot? {
        guard let targetApplication else { return nil }

        let axApp = AXUIElementCreateApplication(targetApplication.processIdentifier)
        guard let focusedElement = copyElementAttribute(axApp, kAXFocusedUIElementAttribute as CFString) else {
            return nil
        }

        for candidate in insertionCandidates(startingAt: focusedElement) {
            if let snapshot = textSnapshot(
                for: candidate,
                bundleID: bundleID,
                windowTitle: windowTitle,
                browserURL: browserURL,
                allowReadOnly: true
            ) {
                return snapshot
            }
        }

        return nil
    }

    private func textSnapshot(
        for candidate: TextInputCandidate,
        bundleID: String? = nil,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        allowReadOnly: Bool = false
    ) -> TextInputSnapshot? {
        guard allowReadOnly || candidate.supportsAXValueInsertion else { return nil }

        let sanitizedValue = AccessibilityPlaceholderFilter.sanitizeFocusedFieldValue(
            candidate.value,
            bundleID: bundleID,
            windowTitle: windowTitle,
            browserURL: browserURL,
            placeholderValue: candidate.placeholderValue
        )
        let baselineValue = sanitizedValue.isEmpty ? "" : sanitizedValue
        let selectedRange = baselineValue.isEmpty ? nil : candidate.selectedRange

        return TextInputSnapshot(
            element: candidate.element,
            value: baselineValue,
            selectedRange: selectedRange,
            targetFingerprint: targetFingerprint(
                for: candidate.element,
                selectedRange: selectedRange
            )
        )
    }

    private func textSnapshot(
        for element: AXUIElement,
        bundleID: String? = nil,
        windowTitle: String? = nil,
        browserURL: String? = nil
    ) -> TextInputSnapshot? {
        guard let candidate = makeTextInputCandidate(element, relation: .focused) else {
            return nil
        }
        return textSnapshot(
            for: candidate,
            bundleID: bundleID,
            windowTitle: windowTitle,
            browserURL: browserURL,
            allowReadOnly: true
        )
    }

    /// Mirrors ContextExtractor's tokenization and bucketing so delivery-time
    /// evidence can be compared with a later hot snapshot without retaining AX
    /// labels or other raw target text.
    private func targetFingerprint(
        for element: AXUIElement,
        selectedRange: CFRange?
    ) -> ContextTargetFingerprint? {
        let role = copyStringAttribute(element, kAXRoleAttribute as CFString)
        let subrole = copyStringAttribute(element, kAXSubroleAttribute as CFString)
        guard role != nil || subrole != nil else { return nil }

        return ContextTargetFingerprint(
            role: role,
            subrole: subrole,
            isSensitiveInput: Self.isSensitiveTextInput(role: role, subrole: subrole),
            identifierToken: Self.stableTargetToken(
                copyStringAttribute(element, kAXIdentifierAttribute as CFString)
            ),
            titleToken: Self.stableTargetToken(
                copyStringAttribute(element, kAXTitleAttribute as CFString)
            ),
            descriptionToken: Self.stableTargetToken(
                copyStringAttribute(element, kAXDescriptionAttribute as CFString)
            ),
            placeholderToken: Self.stableTargetToken(
                copyStringAttribute(element, kAXPlaceholderValueAttribute as CFString)
            ),
            helpToken: Self.stableTargetToken(
                copyStringAttribute(element, kAXHelpAttribute as CFString)
            ),
            frameBucket: targetFrameBucket(for: element),
            selectedRangeBucket: selectedRange.map(Self.selectedRangeBucket)
        )
    }

    private static func isSensitiveTextInput(role: String?, subrole: String?) -> Bool {
        [role, subrole]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains("secure") && $0.contains("text") }
    }

    private func targetFrameBucket(for element: AXUIElement) -> String? {
        guard let position = copyCGPointAttribute(element, kAXPositionAttribute as CFString),
              let size = copyCGSizeAttribute(element, kAXSizeAttribute as CFString) else {
            return nil
        }
        let x = Int((position.x / 80).rounded())
        let y = Int((position.y / 80).rounded())
        let width = Int((size.width / 80).rounded())
        let height = Int((size.height / 40).rounded())
        return "\(x):\(y):\(width):\(height)"
    }

    private func copyCGPointAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private func copyCGSizeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private static func selectedRangeBucket(_ range: CFRange) -> String {
        let location = max(0, range.location / 80)
        let length = max(0, range.length / 20)
        return "\(location):\(length)"
    }

    private static func stableTargetToken(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        return String(fnv1a64(normalized), radix: 16)
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private func appendDescendantCandidates(
        of element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        into candidates: inout [TextInputCandidate],
        visited: inout Set<CFHashCode>
    ) {
        guard depth <= maxDepth else { return }
        for child in copyElementArrayAttribute(element, kAXChildrenAttribute as CFString).prefix(24) {
            let hash = CFHash(child)
            guard !visited.contains(hash) else { continue }
            visited.insert(hash)
            if let candidate = makeTextInputCandidate(child, relation: .descendant(depth: depth)) {
                candidates.append(candidate)
            }
            appendDescendantCandidates(
                of: child,
                depth: depth + 1,
                maxDepth: maxDepth,
                into: &candidates,
                visited: &visited
            )
        }
    }

    private func makeTextInputCandidate(
        _ element: AXUIElement,
        relation: CandidateRelation
    ) -> TextInputCandidate? {
        let role = copyStringAttribute(element, kAXRoleAttribute as CFString)
        let subrole = copyStringAttribute(element, kAXSubroleAttribute as CFString)
        guard isDirectTextInputRole(role: role, subrole: subrole) else {
            return nil
        }

        return TextInputCandidate(
            element: element,
            relation: relation,
            role: role,
            subrole: subrole,
            value: copyStringAttribute(element, kAXValueAttribute as CFString) ?? "",
            placeholderValue: copyStringAttribute(element, kAXPlaceholderValueAttribute as CFString),
            selectedRange: copySelectedRangeAttribute(element),
            isValueSettable: isAttributeSettable(
                element,
                attribute: kAXValueAttribute as CFString
            )
        )
    }

    private func copyElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func copyElementArrayAttribute(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let elements = value as? [AXUIElement] else {
            return []
        }
        return elements
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func isAttributeSettable(_ element: AXUIElement, attribute: CFString) -> Bool {
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute, &isSettable) == .success else {
            return false
        }
        return isSettable.boolValue
    }

    private func copySelectedRangeAttribute(_ element: AXUIElement) -> CFRange? {
        var selectedRangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef) == .success,
              let selectedRangeRef else {
            return nil
        }

        guard CFGetTypeID(selectedRangeRef) == AXValueGetTypeID() else { return nil }
        let axValue = selectedRangeRef as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &selectedRange) else {
            return nil
        }

        return selectedRange
    }

    // MARK: - Smart spacing

    /// Adjusts text for seamless consecutive pastes by reading the surrounding
    /// cursor context via AX:
    ///   - Prepends a space when the immediate preceding char is not whitespace
    ///   - Lowercases the first letter when continuing after prior prose,
    ///     even if the cursor sits after trailing spaces
    ///   - Capitalizes the first letter after a sentence boundary
    ///
    /// Only applies the space/lowercase adjustments when we can verify that
    /// the text before the cursor ends with our own most recent insertion.
    /// Rich text editors (e.g. browser contenteditables) expose AX content
    /// whose cursor/ordering doesn't reliably reflect the caret, so trusting
    /// it causes false positives. Capitalization at field start is safe and
    /// always applies.
    func applySmartSpacing(
        to text: String,
        for targetApplication: NSRunningApplication?,
        bundleID: String?,
        windowTitle: String?,
        browserURL: String?
    ) -> String {
        let textBeforeCursor = textBeforeCursor(
            for: targetApplication,
            bundleID: bundleID,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
        let target = SmartInsertionSpacing.Target(
            bundleID: bundleID,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
        let context = SmartInsertionSpacing.cursorContext(
            textBeforeCursor: textBeforeCursor,
            lastDelivery: lastInsertion,
            target: target
        )

        return SmartInsertionSpacing.adjustedText(
            text,
            context: context
        )
    }

    static func adjustTextForInsertionContext(
        _ text: String,
        textBeforeCursor: String?,
        continuesFromOurInsertion: Bool
    ) -> String {
        SmartInsertionSpacing.adjustedText(
            text,
            context: SmartInsertionSpacing.CursorContext(
                textBeforeCursor: textBeforeCursor,
                continuesFromLastDelivery: continuesFromOurInsertion
            )
        )
    }

    /// Reads the text before the cursor in the focused text field of the target
    /// app. Returns nil if the field is empty or unreadable.
    private func textBeforeCursor(
        for targetApplication: NSRunningApplication?,
        bundleID: String?,
        windowTitle: String?,
        browserURL: String?
    ) -> String? {
        guard let targetApplication else { return nil }
        let axApp = AXUIElementCreateApplication(targetApplication.processIdentifier)
        guard let focused = copyElementAttribute(axApp, kAXFocusedUIElementAttribute as CFString) else {
            return nil
        }

        guard let value = copyStringAttribute(focused, kAXValueAttribute as CFString),
              !value.isEmpty else {
            return nil
        }

        let sanitizedValue = AccessibilityPlaceholderFilter.sanitizeFocusedFieldValue(
            value,
            bundleID: bundleID ?? targetApplication.bundleIdentifier,
            windowTitle: windowTitle,
            browserURL: browserURL,
            placeholderValue: copyStringAttribute(focused, kAXPlaceholderValueAttribute as CFString)
        )
        guard !sanitizedValue.isEmpty else { return nil }

        if let selectedRange = copySelectedRangeAttribute(focused) {
            let cursorPos = selectedRange.location
            guard cursorPos >= 0 else { return nil }

            let nsValue = sanitizedValue as NSString
            let clampedCursorPos = max(0, min(cursorPos, nsValue.length))
            return nsValue.substring(to: clampedCursorPos)
        }

        return sanitizedValue
    }

    private func applyingInsertion(to currentValue: String, selectedRange: CFRange?, insertedText: String) -> (text: String, cursorLocation: Int) {
        guard let selectedRange else {
            let updated = currentValue.isEmpty ? insertedText : currentValue + insertedText
            return (updated, updated.utf16.count)
        }

        let nsValue = currentValue as NSString
        let location = max(0, min(selectedRange.location, nsValue.length))
        let length = max(0, min(selectedRange.length, nsValue.length - location))
        let range = NSRange(location: location, length: length)
        return (
            nsValue.replacingCharacters(in: range, with: insertedText),
            location + insertedText.utf16.count
        )
    }

    private func typingChunkSize(for bundleID: String?) -> Int {
        switch bundleID {
        case "com.openai.codex":
            return 8
        default:
            return 20
        }
    }

    private func typingInterChunkDelay(for bundleID: String?) -> Duration {
        switch bundleID {
        case "com.openai.codex":
            return .milliseconds(12)
        default:
            return .milliseconds(5)
        }
    }

    @MainActor
    private func verificationDelay(for method: DeliveryMethod, bundleID: String?) -> Duration {
        let baseMilliseconds = Self.baseVerificationDelayMilliseconds(for: method, bundleID: bundleID)
        let variant = PerformanceExperiments.shared.assignment(
            for: .pasteVerificationDelay,
            source: "paste_delivery"
        ).variant
        return .milliseconds(Self.adjustedVerificationDelayMilliseconds(
            baseMilliseconds: baseMilliseconds,
            variant: variant
        ))
    }

    private static func baseVerificationDelayMilliseconds(for method: DeliveryMethod, bundleID: String?) -> Int {
        switch (bundleID, method) {
        case ("com.openai.codex", .directTyping):
            return 140
        case ("com.openai.codex", .pasteShortcut):
            return 180
        case (_, .accessibility):
            return 40
        case (_, .directTyping):
            return 90
        case (_, .pasteShortcut):
            return 120
        }
    }

    nonisolated static func adjustedVerificationDelayMilliseconds(
        baseMilliseconds: Int,
        variant: String
    ) -> Int {
        switch variant {
        case "short", "short_80ms":
            return min(baseMilliseconds, 80)
        case "short_60ms":
            return min(baseMilliseconds, 60)
        case "aggressive", "aggressive_40ms":
            return min(baseMilliseconds, 40)
        case "no_wait", "zero":
            return 0
        default:
            return baseMilliseconds
        }
    }

    private func selectionCopyDelay(for targetProfile: TextInputTargetProfile) -> Duration {
        switch targetProfile.kind {
        case .codexApp, .cmuxApp:
            return .milliseconds(180)
        case .claudeWeb, .discordDesktop, .discordWeb, .linkedInWeb:
            return .milliseconds(140)
        case .terminalApp, .electronEditorApp, .firefoxEngineBrowser, .googleDocsWeb, .gmailWeb, .protonMailWeb, .webMailClient, .unknown:
            return .milliseconds(90)
        }
    }

    private func sendDelay(for targetProfile: TextInputTargetProfile) -> Duration {
        targetProfile.autoSendDelay
    }

    private func describe(_ candidate: TextInputCandidate) -> String {
        let relation: String = {
            switch candidate.relation {
            case .focused:
                return "focused"
            case .descendant(let depth):
                return "descendant:\(depth)"
            case .ancestor(let depth):
                return "ancestor:\(depth)"
            }
        }()
        let title = copyStringAttribute(candidate.element, kAXTitleAttribute as CFString) ?? ""
        let placeholder = candidate.placeholderValue ?? ""
        return "score=\(candidate.score),relation=\(relation),role=\(candidate.role ?? "?"),subrole=\(candidate.subrole ?? "-"),title=\(title),placeholder=\(placeholder)"
    }

    private func describe(_ selectedRange: SelectionRange?) -> String {
        guard let selectedRange else { return "nil" }
        return "loc=\(selectedRange.location),len=\(selectedRange.length)"
    }

    private func debugLog(_ message: String) {
        // Unified log so paste failures stay diagnosable in release builds
        // (`log show --predicate 'subsystem == "com.resonance.resonant"'`).
        Self.log.notice("\(message, privacy: .public)")
#if DEBUG
        print("[PasteManager] \(message)")
#endif
    }

    private func resolveTargetApplication(preferred: NSRunningApplication?) -> NSRunningApplication? {
        if let frontmost = frontmostApplication() {
            return frontmost
        }

        guard let preferred,
              !preferred.isTerminated else {
            return nil
        }

        return preferred
    }

    private func frontmostApplication() -> NSRunningApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              !application.isTerminated else {
            return nil
        }

        return application
    }

    private func isFrontmost(_ application: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
    }

    private func syntheticInputTargetIsCurrent(
        _ expectedTargetApplication: NSRunningApplication?
    ) -> Bool {
        Self.syntheticInputTargetMatches(
            expectedProcessIdentifier: expectedTargetApplication?.processIdentifier,
            frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
    }

    /// Last-resort sanity check for deliveries that cannot be verified via AX:
    /// synthetic events always go to the frontmost app, so if the target is no
    /// longer frontmost the text landed somewhere else (or nowhere).
    private func unverifiedDeliveryStayedOnTarget(
        _ targetApplication: NSRunningApplication?,
        bundleID: String?,
        method: String
    ) -> Bool {
        if let targetApplication, !isFrontmost(targetApplication) {
            debugLog("\(method) posted without baseline and \(bundleID ?? "target") is no longer frontmost — reporting failure")
            return false
        }
        debugLog("\(method) posted without verification baseline — assuming success")
        return true
    }

    private static func syntheticKeyboardEventSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .privateState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [],
            state: .eventSuppressionStateSuppressionInterval
        )
        return source
    }

    private func isSecureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }

    private func waitForSyntheticInputModifiersToSettle() async {
        for attempt in 0..<3 {
            let blockingFlags = Self.blockingSyntheticInputModifierFlags(
                from: CGEventSource.flagsState(.combinedSessionState)
            )
            guard !blockingFlags.isEmpty else { return }

            if attempt == 0 {
                debugLog("Waiting for hardware modifiers to settle before synthetic input: \(blockingFlags.rawValue)")
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let blockingFlags = Self.blockingSyntheticInputModifierFlags(
            from: CGEventSource.flagsState(.combinedSessionState)
        )
        if !blockingFlags.isEmpty {
            debugLog("Posting synthetic input while hardware modifiers remain down: \(blockingFlags.rawValue)")
        }
    }

    private func simulateCmdV(
        expectedTargetApplication: NSRunningApplication?
    ) async -> Bool {
        guard syntheticInputTargetIsCurrent(expectedTargetApplication) else {
            debugLog("No frontmost target application for Cmd+V")
            lastDeliveryFailure = expectedTargetApplication == nil
                ? .noFrontmostTarget
                : .targetActivationFailed
            return false
        }

        guard !isSecureInputActive() else {
            debugLog("Secure Event Input is active; skipping Cmd+V")
            lastDeliveryFailure = .secureInputActive
            return false
        }

        // Brief delay to ensure target app is focused
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled else { return false }

        guard !isSecureInputActive() else {
            debugLog("Secure Event Input became active before Cmd+V")
            lastDeliveryFailure = .secureInputActive
            return false
        }

        await waitForSyntheticInputModifiersToSettle()
        guard !Task.isCancelled else { return false }
        guard syntheticInputTargetIsCurrent(expectedTargetApplication) else {
            lastDeliveryFailure = .targetActivationFailed
            return false
        }
        guard !isSecureInputActive() else {
            lastDeliveryFailure = .secureInputActive
            return false
        }

        let src = Self.syntheticKeyboardEventSource()
        let commandKey: CGKeyCode = 55
        let vKey: CGKeyCode = 9

        guard let commandDown = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: false)
        else {
            debugLog("CGEvent creation failed for Cmd+V (source \(src == nil ? "unavailable" : "ok"))")
            return false
        }

        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags   = .maskCommand
        commandUp.flags = []

        commandDown.post(tap: .cghidEventTap)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)

        return true
    }

    private func simulateCmdC(
        expectedTargetApplication: NSRunningApplication?
    ) async -> Bool {
        guard syntheticInputTargetIsCurrent(expectedTargetApplication) else {
            debugLog("No frontmost target application for Cmd+C")
            lastDeliveryFailure = expectedTargetApplication == nil
                ? .noFrontmostTarget
                : .targetActivationFailed
            return false
        }

        guard !isSecureInputActive() else {
            debugLog("Secure Event Input is active; skipping Cmd+C")
            lastDeliveryFailure = .secureInputActive
            return false
        }

        try? await Task.sleep(for: .milliseconds(50))

        guard !isSecureInputActive() else {
            debugLog("Secure Event Input became active before Cmd+C")
            lastDeliveryFailure = .secureInputActive
            return false
        }

        await waitForSyntheticInputModifiersToSettle()
        guard syntheticInputTargetIsCurrent(expectedTargetApplication) else {
            lastDeliveryFailure = .targetActivationFailed
            return false
        }
        guard !isSecureInputActive() else {
            lastDeliveryFailure = .secureInputActive
            return false
        }

        let src = Self.syntheticKeyboardEventSource()
        let commandKey: CGKeyCode = 55
        let cKey: CGKeyCode = 8

        guard let commandDown = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: false)
        else {
            debugLog("CGEvent creation failed for Cmd+C (source \(src == nil ? "unavailable" : "ok"))")
            return false
        }

        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        commandUp.flags = []

        commandDown.post(tap: .cghidEventTap)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)

        return true
    }

    // MARK: - Pasteboard snapshot

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private struct PasteboardWrite {
        let snapshot: PasteboardSnapshot?
        let restoreChangeCount: Int?
    }

    @MainActor
    private func preparePasteboardForPaste(text: String, restoreClipboard: Bool) -> PasteboardWrite? {
        let pasteboard = NSPasteboard.general
        let snapshot = restoreClipboard ? snapshotPasteboard(pasteboard) : nil
        guard write(text: text, to: pasteboard, transient: restoreClipboard) else {
            return nil
        }

        return PasteboardWrite(
            snapshot: snapshot,
            restoreChangeCount: snapshot != nil ? pasteboard.changeCount : nil
        )
    }

    private func snapshotPasteboard(_ pb: NSPasteboard) -> PasteboardSnapshot {
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in Self.safePasteboardItems(from: pb) {
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in Self.safePasteboardTypes(from: item) {
                guard let data = Self.safePasteboardData(from: item, for: type) else { continue }
                dict[type] = data
            }
            items.append(dict)
        }
        return PasteboardSnapshot(items: items)
    }

    private func restorePasteboard(_ pb: NSPasteboard, snapshot: PasteboardSnapshot) {
        pb.clearContents()
        let pbItems = snapshot.items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        if !pbItems.isEmpty {
            pb.writeObjects(pbItems)
        }
    }

    @MainActor
    private func scheduleClipboardRestoreIfNeeded(after pasteboardWrite: PasteboardWrite) {
        guard let snapshot = pasteboardWrite.snapshot,
              let expectedChangeCount = pasteboardWrite.restoreChangeCount else {
            return
        }

        let pasteboard = NSPasteboard.general
        Task { @MainActor [clipboardRestoreDelay] in
            try? await Task.sleep(for: clipboardRestoreDelay)
            restorePasteboardIfStillOwned(
                pasteboard,
                snapshot: snapshot,
                expectedChangeCount: expectedChangeCount
            )
        }
    }

    @MainActor
    private func restoreClipboardIfNeeded(after pasteboardWrite: PasteboardWrite) {
        guard let snapshot = pasteboardWrite.snapshot,
              let expectedChangeCount = pasteboardWrite.restoreChangeCount else {
            return
        }

        restorePasteboardIfStillOwned(
            NSPasteboard.general,
            snapshot: snapshot,
            expectedChangeCount: expectedChangeCount
        )
    }

    private func restorePasteboardIfStillOwned(
        _ pb: NSPasteboard,
        snapshot: PasteboardSnapshot,
        expectedChangeCount: Int
    ) {
        guard pb.changeCount == expectedChangeCount else { return }
        guard Self.hasTransientPasteboardMarker(pb) else { return }
        restorePasteboard(pb, snapshot: snapshot)
    }

    static func hasTransientPasteboardMarker(_ pb: NSPasteboard) -> Bool {
        for item in safePasteboardItems(from: pb) {
            if safePasteboardTypes(from: item).contains(Self.transientType) {
                return true
            }
        }
        return false
    }

    private static func safePasteboardItems(from pb: NSPasteboard) -> [NSPasteboardItem] {
        var exception: NSException?
        let items = ObjCSafePasteboardItems(pb, &exception)
        logPasteboardException(exception, operation: "read items")
        return items
    }

    private static func safePasteboardTypes(from item: NSPasteboardItem) -> [NSPasteboard.PasteboardType] {
        var exception: NSException?
        let types = ObjCSafePasteboardTypes(item, &exception)
        logPasteboardException(exception, operation: "read types")
        return types
    }

    private static func safePasteboardData(
        from item: NSPasteboardItem,
        for type: NSPasteboard.PasteboardType
    ) -> Data? {
        var exception: NSException?
        let data = ObjCSafePasteboardItemData(item, type, &exception) as Data?
        logPasteboardException(exception, operation: "read data for \(type.rawValue)")
        return data
    }

    private static func logPasteboardException(_ exception: NSException?, operation: String) {
        guard let exception else { return }
        log.error("Pasteboard \(operation, privacy: .public) threw \(exception.name.rawValue, privacy: .public): \(exception.reason ?? "no reason", privacy: .public)")
    }

    // Regex matching Markdown links: [label](url)
    private static let markdownLinkPattern = try! NSRegularExpression(
        pattern: #"\[([^\]]+)\]\(([^)]+)\)"#
    )

    private static func containsMarkdownLinks(_ text: String) -> Bool {
        markdownLinkPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Final plain-text transform applied after smart spacing and before any
    /// delivery method receives the text.
    static func effectiveInsertedPlainText(afterSmartSpacing text: String) -> String {
        strippingMarkdownLinks(text)
    }

    /// Strips Markdown link syntax, keeping only the label text.
    private static func strippingMarkdownLinks(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return markdownLinkPattern.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "$1"
        )
    }

    static func htmlFromMarkdownLinks(_ text: String) -> String {
        let normalizedText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let range = NSRange(normalizedText.startIndex..., in: normalizedText)
        let matches = markdownLinkPattern.matches(in: normalizedText, range: range)
        let nsText = normalizedText as NSString

        var htmlBody = ""
        var currentLocation = 0

        for match in matches {
            let prefixLength = match.range.location - currentLocation
            if prefixLength > 0 {
                let prefixRange = NSRange(location: currentLocation, length: prefixLength)
                htmlBody += htmlEscapedText(nsText.substring(with: prefixRange))
            }

            let label = nsText.substring(with: match.range(at: 1))
            let url = nsText.substring(with: match.range(at: 2))
            htmlBody += #"<a href="\#(htmlEscapedAttribute(url))">\#(htmlEscapedText(label))</a>"#
            currentLocation = match.range.location + match.range.length
        }

        if currentLocation < nsText.length {
            let suffixRange = NSRange(location: currentLocation, length: nsText.length - currentLocation)
            htmlBody += htmlEscapedText(nsText.substring(with: suffixRange))
        }

        return htmlDocument(body: htmlBody)
    }

    private static func htmlDocument(body htmlBody: String) -> String {
        """
        <html><head><meta charset="utf-8"><style>body{margin:0}.resonant-paste{font:inherit;font-family:inherit;font-size:inherit;color:inherit}.resonant-paste a{font:inherit;font-family:inherit;font-size:inherit;color:#0000EE;text-decoration:underline}</style></head><body><span class="resonant-paste">\(htmlBody)</span></body></html>
        """
    }

    private static func htmlEscapedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func htmlEscapedAttribute(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func setHTMLRepresentation(forHTML html: String, on pasteboard: NSPasteboard) {
        guard let htmlData = html.data(using: .utf8) else {
            log.error("HTML pasteboard representation skipped — UTF-8 encoding failed")
            return
        }
        if !pasteboard.setData(htmlData, forType: .html) {
            log.error("Pasteboard rejected HTML representation write — falling back to plain text only")
        }
    }

    private func write(text: String, to pasteboard: NSPasteboard, transient: Bool) -> Bool {
        pasteboard.clearContents()

        let range = NSRange(text.startIndex..., in: text)
        let hasLinks = Self.containsMarkdownLinks(text)

        let wroteString: Bool
        if hasLinks {
            let html = Self.htmlFromMarkdownLinks(text)
            Self.setHTMLRepresentation(forHTML: html, on: pasteboard)

            // Plain-text fallback: strip markdown syntax → just the label
            let plainText = Self.markdownLinkPattern.stringByReplacingMatches(
                in: text,
                range: range,
                withTemplate: "$1"
            )
            wroteString = pasteboard.setString(plainText, forType: .string)
        } else {
            wroteString = pasteboard.setString(text, forType: .string)
        }

        if !wroteString {
            Self.log.error("Pasteboard rejected string write (length=\(text.count)) — delivery will fail")
        }
        if transient, !pasteboard.setData(Data(), forType: Self.transientType) {
            Self.log.error("Pasteboard rejected transient marker write — clipboard restore may be skipped")
        }
        return wroteString
    }
}

// MARK: - String chunking helper

private extension String {
    func chunked(into size: Int) -> [String] {
        var result: [String] = []
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[start..<end]))
            start = end
        }
        return result
    }
}
