import AppKit
import Foundation

/// Extracts context from the frontmost app via AX API for post-processing.
/// Per-app specialization: code editors, Slack, browsers.
final class ContextExtractor {

    struct Context: Sendable {
        var appName: String = ""
        var bundleId: String = ""
        var windowTitle: String = ""
        var selectedText: String = ""
        var selectedRange: SelectionRange?
        var browserURL: String = ""
        var codeFiles: [String] = []
        var slackMembers: [String] = []
        var focusedFieldContent: String = ""
        var targetFingerprint: ContextTargetFingerprint? = nil
        var visibleTextSnippets: [String] = []

        var primaryCodeFile: String? {
            codeFiles.first(where: { !$0.isEmpty })
        }

        var primarySlackRecipient: String? {
            slackMembers.first(where: { !$0.isEmpty })
        }
    }

    /// Fields the delivery path needs before a paste can land.
    struct HotContext: Sendable {
        var appName: String = ""
        var bundleId: String = ""
        var windowTitle: String = ""
        var browserURL: String = ""
        var selectedText: String = ""
        var selectedRange: SelectionRange?
        var focusedFieldContent: String = ""
        var targetFingerprint: ContextTargetFingerprint? = nil
        var activeRecipient: ActiveRecipientContext? = nil
    }

    /// Fields used only by feed/analytics/ambient/journal — not by delivery.
    struct ColdContext: Sendable {
        var codeFiles: [String] = []
        var slackMembers: [String] = []
        var visibleTextSnippets: [String] = []

        var primaryCodeFile: String? {
            codeFiles.first(where: { !$0.isEmpty })
        }

        var primarySlackRecipient: String? {
            slackMembers.first(where: { !$0.isEmpty })
        }
    }

    private struct ExtractionRequest: Sendable {
        let processIdentifier: pid_t
        let appName: String
        let bundleId: String
        let captureRichContext: Bool
    }

    private struct ColdExtractionRequest: Sendable {
        let processIdentifier: pid_t
        let bundleId: String
        let windowTitle: String
        let browserURL: String
    }

    private struct CorrectionExtractionRequest: Sendable {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
    }

    private struct ActiveRecipientExtractionRequest: Sendable {
        let processIdentifier: pid_t
        let expectedTargetFingerprint: ContextTargetFingerprint
    }

    // MARK: - Extract

    func extract() async -> Context {
        await extract(from: NSWorkspace.shared.frontmostApplication)
    }

    func extract(
        from app: NSRunningApplication?,
        captureRichContext: Bool = true,
        allowBrowserAutomationFallback: Bool = true
    ) async -> Context {
        let hot = await extractHot(
            from: app,
            allowBrowserAutomationFallback: allowBrowserAutomationFallback
        )
        guard captureRichContext else {
            return Self.composeContext(app: app, hot: hot, cold: ColdContext())
        }
        let cold = await extractCold(
            from: app,
            bundleId: hot.bundleId,
            windowTitle: hot.windowTitle,
            browserURL: hot.browserURL
        )
        return Self.composeContext(app: app, hot: hot, cold: cold)
    }

    /// Hot path: only the fields the delivery pipeline reads before paste lands.
    /// Runs the AX queries needed for delivery on a `userInitiated` detached task,
    /// then optionally falls back to browser automation for window/URL.
    func extractHot(
        from app: NSRunningApplication?,
        allowBrowserAutomationFallback: Bool = true
    ) async -> HotContext {
        guard let app else { return HotContext() }

        let request = ExtractionRequest(
            processIdentifier: app.processIdentifier,
            appName: app.localizedName ?? "",
            bundleId: app.bundleIdentifier ?? "",
            captureRichContext: true
        )

        var hot = await Task.detached(priority: .userInitiated) {
            Self.extractHotContext(from: request)
        }.value

        if BrowserCatalog.isBrowser(request.bundleId) {
            let bundleId = request.bundleId
            let windowTitle = hot.windowTitle
            let browserURL = hot.browserURL
            let browserContext = await Task.detached(priority: .utility) {
                BrowserAutomationSupport.fallbackContext(
                    bundleId: bundleId,
                    currentWindowTitle: windowTitle,
                    currentURL: browserURL,
                    allowUserPrompt: allowBrowserAutomationFallback
                )
            }.value
            if let browserContext {
                if hot.windowTitle.isEmpty, let title = browserContext.windowTitle {
                    hot.windowTitle = title
                }
                if hot.browserURL.isEmpty, let url = browserContext.browserURL {
                    hot.browserURL = url
                }
            }
        }

        return hot
    }

    /// Correction-only AX path. It captures the complete focused-field value,
    /// target identity, and sensitivity from one focused element on a detached
    /// task. Unlike the delivery hot context, the field value is not truncated
    /// and no browser automation or ambient persistence is involved.
    func extractCorrectionHotSnapshot(
        from app: NSRunningApplication?
    ) async -> CorrectionHotSnapshot? {
        guard let app else { return nil }
        let request = CorrectionExtractionRequest(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier
        )
        return await Task.detached(priority: .userInitiated) {
            Self.extractCorrectionHotSnapshot(from: request)
        }.value
    }

    /// Creates a separately cancellable, opportunistic AX traversal. This task
    /// is never joined to `extractHot`, which is awaited by the stop pipeline.
    /// Key-up cancels this exact handle and snapshots only a result that was
    /// already published by the capture session.
    func makeActiveRecipientExtractionTask(
        from app: NSRunningApplication?,
        hot: HotContext
    ) -> Task<ActiveRecipientContext?, Never>? {
        guard let app,
              ActiveRecipientEligibility.allows(hot: hot),
              let expectedTargetFingerprint = hot.targetFingerprint else {
            return nil
        }
        let request = ActiveRecipientExtractionRequest(
            processIdentifier: app.processIdentifier,
            expectedTargetFingerprint: expectedTargetFingerprint
        )
        return Task.detached(priority: .utility) {
            Self.extractActiveRecipientContext(from: request)
        }
    }

    /// Cold path: rich metadata used by the feed and analytics. Runs at
    /// `.utility` priority so it doesn't compete with the delivery hot path.
    func extractCold(
        from app: NSRunningApplication?,
        bundleId: String,
        windowTitle: String,
        browserURL: String
    ) async -> ColdContext {
        guard let app else { return ColdContext() }
        let request = ColdExtractionRequest(
            processIdentifier: app.processIdentifier,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL
        )
        return await Task.detached(priority: .utility) {
            Self.extractColdContext(from: request)
        }.value
    }

    private static func composeContext(
        app: NSRunningApplication?,
        hot: HotContext,
        cold: ColdContext
    ) -> Context {
        var context = Context()
        context.appName = hot.appName.isEmpty ? (app?.localizedName ?? "") : hot.appName
        context.bundleId = hot.bundleId.isEmpty ? (app?.bundleIdentifier ?? "") : hot.bundleId
        context.windowTitle = hot.windowTitle
        context.browserURL = hot.browserURL
        context.selectedText = hot.selectedText
        context.selectedRange = hot.selectedRange
        context.focusedFieldContent = hot.focusedFieldContent
        context.targetFingerprint = hot.targetFingerprint
        context.codeFiles = cold.codeFiles
        context.slackMembers = cold.slackMembers
        context.visibleTextSnippets = cold.visibleTextSnippets
        return context
    }

    // MARK: - Extraction internals

    private static func extractHotContext(from request: ExtractionRequest) -> HotContext {
        var hot = HotContext()
        hot.appName = request.appName
        hot.bundleId = request.bundleId

        let axApp = AXUIElementCreateApplication(request.processIdentifier)
        let focused = focusedElement(axApp: axApp)

        hot.windowTitle = windowTitle(axApp: axApp)
        let (selText, selRange) = selectedTextAndRange(axApp: axApp)
        hot.selectedText = selText
        hot.selectedRange = selRange
        hot.targetFingerprint = focusedTargetFingerprint(
            focusedElement: focused,
            selectedRange: selRange
        )

        if isBrowser(request.bundleId) {
            hot.browserURL = browserURL(axApp: axApp)
        }

        let targetProfile = TextInputTargetProfile(
            bundleID: request.bundleId,
            windowTitle: hot.windowTitle,
            browserURL: hot.browserURL
        )

        if targetProfile.capturesFocusedFieldValue {
            hot.focusedFieldContent = focusedFieldContent(
                focusedElement: focused,
                bundleId: request.bundleId,
                windowTitle: hot.windowTitle,
                browserURL: hot.browserURL
            )
        }
        return hot
    }

    private static func extractColdContext(from request: ColdExtractionRequest) -> ColdContext {
        var cold = ColdContext()
        let axApp = AXUIElementCreateApplication(request.processIdentifier)

        switch request.bundleId {
        case let id where isCodeEditor(id):
            cold.codeFiles = extractCodeFiles(axApp: axApp)
        case "com.tinyspeck.slackmacgap":
            cold.slackMembers = extractSlackMembers(axApp: axApp)
        default:
            break
        }

        let targetProfile = TextInputTargetProfile(
            bundleID: request.bundleId,
            windowTitle: request.windowTitle,
            browserURL: request.browserURL
        )

        if targetProfile.collectsVisibleTextSnippets {
            let focused = focusedElement(axApp: axApp)
            cold.visibleTextSnippets = visibleTextSnippets(
                axApp: axApp,
                bundleId: request.bundleId,
                windowTitle: request.windowTitle,
                browserURL: request.browserURL,
                excludedSubtreeRoot: focused
            )
        }

        return cold
    }

    private static func extractCorrectionHotSnapshot(
        from request: CorrectionExtractionRequest
    ) -> CorrectionHotSnapshot? {
        let axApp = AXUIElementCreateApplication(request.processIdentifier)
        guard let focused = focusedElement(axApp: axApp) else { return nil }

        let selectedRange = selectedRange(from: focused)
        let fingerprint = focusedTargetFingerprint(
            focusedElement: focused,
            selectedRange: selectedRange
        )
        let fullFieldContent = correctionFocusedFieldContent(
            focusedElement: focused,
            bundleIdentifier: request.bundleIdentifier
        )
        return CorrectionHotSnapshot(
            fullFieldContent: fullFieldContent,
            processIdentifier: request.processIdentifier,
            bundleIdentifier: request.bundleIdentifier,
            isSensitiveInput: fingerprint?.isSensitiveInput,
            targetFingerprint: fingerprint
        )
    }

    private static func extractActiveRecipientContext(
        from request: ActiveRecipientExtractionRequest
    ) -> ActiveRecipientContext? {
        guard !Task.isCancelled else { return nil }
        let deadline = DispatchTime.now().uptimeNanoseconds + 220_000_000
        let axApp = AXUIElementCreateApplication(request.processIdentifier)
        guard let focused = focusedElement(axApp: axApp),
              activeRecipientFingerprint(
                for: focused,
                expected: request.expectedTargetFingerprint
              ) == request.expectedTargetFingerprint,
              let composerFrame = frame(for: focused) else {
            return nil
        }

        let focusedSemantics = [
            copyStringAttribute(focused, kAXRoleAttribute as CFString),
            copyStringAttribute(focused, kAXSubroleAttribute as CFString),
            copyStringAttribute(focused, kAXIdentifierAttribute as CFString),
            copyStringAttribute(focused, kAXTitleAttribute as CFString),
            copyStringAttribute(focused, kAXDescriptionAttribute as CFString),
            copyStringAttribute(focused, kAXPlaceholderValueAttribute as CFString),
            copyStringAttribute(focused, kAXHelpAttribute as CFString),
        ].compactMap { $0 }
        guard ActiveRecipientEligibility.focusedElementLooksLikeConversationComposer(
            attributes: focusedSemantics
        ) else {
            return nil
        }

        var current = focused
        var seenFrames = Set<String>()
        var remainingNodes = 320
        for _ in 0..<9 {
            guard !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds <= deadline,
                  remainingNodes > 0,
                  let parent = copyElementAttribute(
                      current,
                      kAXParentAttribute as CFString
                  ) else {
                return nil
            }
            current = parent
            guard let scopeFrame = frame(for: parent),
                  plausibleRecipientScope(
                      scopeFrame,
                      composerFrame: composerFrame
                  ) else {
                continue
            }
            let frameKey = [
                Int(scopeFrame.minX.rounded()),
                Int(scopeFrame.minY.rounded()),
                Int(scopeFrame.width.rounded()),
                Int(scopeFrame.height.rounded()),
            ].map(String.init).joined(separator: ":")
            guard seenFrames.insert(frameKey).inserted else { continue }

            let evidence = activeRecipientEvidence(
                in: parent,
                excluding: focused,
                scopeFrame: scopeFrame,
                deadline: deadline,
                remainingNodes: &remainingNodes
            )
            guard let recipient = ActiveRecipientResolver.resolve(
                scopeFrame: scopeFrame,
                composerFrame: composerFrame,
                evidence: evidence
            ) else {
                continue
            }
            guard !Task.isCancelled,
                  let focusedAfterTraversal = focusedElement(axApp: axApp),
                  CFEqual(focusedAfterTraversal, focused),
                  activeRecipientFingerprint(
                      for: focusedAfterTraversal,
                      expected: request.expectedTargetFingerprint
                  ) == request.expectedTargetFingerprint else {
                return nil
            }
            return recipient
        }
        return nil
    }

    private static func activeRecipientFingerprint(
        for focused: AXUIElement,
        expected: ContextTargetFingerprint
    ) -> ContextTargetFingerprint? {
        let selectedRange = expected.selectedRangeBucket == nil
            ? nil
            : selectedRange(from: focused)
        return focusedTargetFingerprint(
            focusedElement: focused,
            selectedRange: selectedRange
        )
    }

    private static func plausibleRecipientScope(
        _ scopeFrame: CGRect,
        composerFrame: CGRect
    ) -> Bool {
        guard scopeFrame.width >= 220,
              scopeFrame.height >= 180,
              scopeFrame.width <= 1_200,
              scopeFrame.height <= 1_200,
              scopeFrame.width >= composerFrame.width * 0.85,
              scopeFrame.width <= max(composerFrame.width * 2.4, 560),
              scopeFrame.contains(CGPoint(x: composerFrame.midX, y: composerFrame.midY))
        else {
            return false
        }
        return true
    }

    private static func activeRecipientEvidence(
        in root: AXUIElement,
        excluding focused: AXUIElement,
        scopeFrame: CGRect,
        deadline: UInt64,
        remainingNodes: inout Int
    ) -> [ActiveRecipientEvidence] {
        var evidence: [ActiveRecipientEvidence] = []
        var queue: [(
            element: AXUIElement,
            depth: Int,
            inheritedPrimaryKind: ActiveRecipientEvidenceKind?
        )] = [(root, 0, nil)]
        var index = 0

        while index < queue.count, remainingNodes > 0 {
            guard !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds <= deadline else {
                break
            }
            let item = queue[index]
            index += 1
            remainingNodes -= 1
            guard item.depth <= 7 else { continue }
            if CFEqual(item.element, focused) {
                continue
            }
            if copyBooleanAttribute(
                item.element,
                "AXHidden" as CFString
            ) == true {
                continue
            }

            let role = copyStringAttribute(
                item.element,
                kAXRoleAttribute as CFString
            ) ?? ""
            let itemFrame = frame(for: item.element) ?? .null
            let clippedFrame = itemFrame.intersection(scopeFrame)
            let batch = ActiveRecipientEvidenceFactory.make(
                role: role,
                title: copyStringAttribute(
                    item.element,
                    kAXTitleAttribute as CFString
                ),
                value: copyStringAttribute(
                    item.element,
                    kAXValueAttribute as CFString
                ),
                description: copyStringAttribute(
                    item.element,
                    kAXDescriptionAttribute as CFString
                ),
                help: copyStringAttribute(
                    item.element,
                    kAXHelpAttribute as CFString
                ),
                frame: clippedFrame,
                inheritedPrimaryKind: item.inheritedPrimaryKind
            )
            if !clippedFrame.isNull, !clippedFrame.isEmpty {
                evidence.append(contentsOf: batch.evidence)
            }

            guard item.depth < 7,
                  !Task.isCancelled,
                  let children = copyElementArrayAttribute(
                      item.element,
                      "AXVisibleChildren" as CFString
                  ) ?? copyElementArrayAttribute(
                      item.element,
                      kAXChildrenAttribute as CFString
                  ) else {
                continue
            }
            queue.append(contentsOf: children.prefix(40).map {
                (
                    element: $0,
                    depth: item.depth + 1,
                    inheritedPrimaryKind: batch.descendantPrimaryKind
                )
            })
        }
        return evidence
    }

    // MARK: - Window title

    static func windowTitle(axApp: AXUIElement) -> String {
        var windows: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windows) == .success,
              let windowList = windows as? [AXUIElement],
              let first = windowList.first else { return "" }

        var title: AnyObject?
        guard AXUIElementCopyAttributeValue(first, kAXTitleAttribute as CFString, &title) == .success else { return "" }
        return title as? String ?? ""
    }

    // MARK: - Selected text

    private static func selectedTextAndRange(axApp: AXUIElement) -> (text: String, range: SelectionRange?) {
        guard let focused = focusedElement(axApp: axApp) else { return ("", nil) }
        return selectedTextAndRange(from: focused)
    }

    private static func selectedTextAndRange(from element: AXUIElement) -> (text: String, range: SelectionRange?) {
        var selected: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, !text.isEmpty else { return ("", nil) }

        var rangeRef: AnyObject?
        var selRange: SelectionRange?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef,
           CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            let axValue = rangeRef as! AXValue
            if AXValueGetType(axValue) == .cfRange {
                var cfRange = CFRange()
                if AXValueGetValue(axValue, .cfRange, &cfRange) {
                    selRange = SelectionRange(location: cfRange.location, length: cfRange.length)
                }
            }
        }

        return (text, selRange)
    }

    private static func selectedRange(from element: AXUIElement) -> SelectionRange? {
        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
        let rangeRef,
        CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = rangeRef as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return SelectionRange(location: range.location, length: range.length)
    }

    // MARK: - Code editor files

    private static let codeEditorBundles: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed",
        "com.barebones.bbedit",
    ]

    private static func isCodeEditor(_ bundleId: String) -> Bool {
        codeEditorBundles.contains(bundleId)
    }

    private static func extractCodeFiles(axApp: AXUIElement) -> [String] {
        var result: [String] = []
        walkTree(element: axApp, depth: 0, maxDepth: 6) { element in
            var role: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            guard role as? String == kAXStaticTextRole || role as? String == "AXButton" else { return true }

            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success ||
               AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success {
                if let text = value as? String, isCodeFileName(text) {
                    result.append(text)
                }
            }
            return true
        }
        return Array(Set(result)).sorted()
    }

    private static let codeExtensions = Set([
        "swift", "ts", "tsx", "js", "jsx", "py", "go", "rs",
        "java", "kt", "cpp", "c", "h", "cs", "vue", "rb"
    ])

    private static func isCodeFileName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return codeExtensions.contains(ext)
    }

    // MARK: - Slack members

    private static func extractSlackMembers(axApp: AXUIElement) -> [String] {
        var result: [String] = []
        walkTree(element: axApp, depth: 0, maxDepth: 8) { element in
            var role: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            guard role as? String == kAXStaticTextRole else { return true }

            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
               let text = value as? String,
               looksLikePersonName(text) {
                result.append(text)
            }
            return true
        }
        return Array(Set(result))
    }

    private static func looksLikePersonName(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard words.count >= 2, words.count <= 4 else { return false }
        return words.allSatisfy { $0.first?.isUppercase == true }
    }

    // MARK: - Browser URL

    private static func isBrowser(_ bundleId: String) -> Bool {
        BrowserCatalog.isBrowser(bundleId)
    }

    static func browserURL(axApp: AXUIElement) -> String {
        let urlRoles: Set<String> = [kAXTextFieldRole, "AXComboBox"]
        var result = ""
        walkTree(element: axApp, depth: 0, maxDepth: 6) { element in
            var role: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            guard let roleStr = role as? String, urlRoles.contains(roleStr) else { return true }

            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
               let text = value as? String,
               looksLikeURL(text) {
                result = text.hasPrefix("http") ? text : "https://\(text)"
                return false
            }
            return true
        }
        return result
    }

    /// Matches full URLs (`https://…`) and bare domains (`threads.net`, `linear.app/…`).
    static func looksLikeURL(_ text: String) -> Bool {
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return true }
        // Bare domain: at least one dot, no spaces, TLD-like suffix before any path
        guard !text.contains(" "), let dotIndex = text.firstIndex(of: ".") else { return false }
        let afterDot = text[text.index(after: dotIndex)...]
        let tldPart = afterDot.prefix(while: { $0 != "/" && $0 != ":" && $0 != "?" })
        return tldPart.count >= 2 && tldPart.allSatisfy(\.isLetter)
    }

    // MARK: - Focused field content

    private static let textInputRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, "AXComboBox"
    ]

    private static func focusedFieldContent(
        focusedElement: AXUIElement?,
        bundleId: String,
        windowTitle: String,
        browserURL: String
    ) -> String {
        guard let ax = focusedElement else { return "" }
        var role: AnyObject?
        AXUIElementCopyAttributeValue(ax, kAXRoleAttribute as CFString, &role)
        guard let roleStr = role as? String, textInputRoles.contains(roleStr) else { return "" }

        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(ax, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return "" }
        let placeholderValue = copyStringAttribute(ax, kAXPlaceholderValueAttribute as CFString)

        let sanitized = AccessibilityPlaceholderFilter.sanitizeFocusedFieldValue(
            text,
            bundleID: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL,
            placeholderValue: placeholderValue
        )
        guard !sanitized.isEmpty else { return "" }
        return String(sanitized.prefix(2000))
    }

    private static func correctionFocusedFieldContent(
        focusedElement: AXUIElement,
        bundleIdentifier: String?
    ) -> String {
        let role = copyStringAttribute(
            focusedElement,
            kAXRoleAttribute as CFString
        )
        guard let role, textInputRoles.contains(role),
              let value = copyStringAttribute(
                focusedElement,
                kAXValueAttribute as CFString
              ) else {
            return ""
        }
        return AccessibilityPlaceholderFilter.sanitizeFocusedFieldValue(
            value,
            bundleID: bundleIdentifier,
            placeholderValue: copyStringAttribute(
                focusedElement,
                kAXPlaceholderValueAttribute as CFString
            )
        )
    }

    private static func focusedTargetFingerprint(
        focusedElement: AXUIElement?,
        selectedRange: SelectionRange?
    ) -> ContextTargetFingerprint? {
        guard let ax = focusedElement else { return nil }

        let role = copyStringAttribute(ax, kAXRoleAttribute as CFString)
        let subrole = copyStringAttribute(ax, kAXSubroleAttribute as CFString)
        guard role != nil || subrole != nil else { return nil }

        return ContextTargetFingerprint(
            role: role,
            subrole: subrole,
            isSensitiveInput: isSensitiveTextInput(role: role, subrole: subrole),
            identifierToken: stableToken(copyStringAttribute(ax, kAXIdentifierAttribute as CFString)),
            titleToken: stableToken(copyStringAttribute(ax, kAXTitleAttribute as CFString)),
            descriptionToken: stableToken(copyStringAttribute(ax, kAXDescriptionAttribute as CFString)),
            placeholderToken: stableToken(copyStringAttribute(ax, kAXPlaceholderValueAttribute as CFString)),
            helpToken: stableToken(copyStringAttribute(ax, kAXHelpAttribute as CFString)),
            frameBucket: frameBucket(for: ax),
            selectedRangeBucket: selectedRange.map(selectedRangeBucket)
        )
    }

    private static func isSensitiveTextInput(role: String?, subrole: String?) -> Bool {
        [role, subrole]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains("secure") && $0.contains("text") }
    }

    // MARK: - Visible text snippets

    private static let snippetRoles: Set<String> = [
        kAXStaticTextRole, "AXButton", "AXHeading", "AXLink", "AXCell", "AXMenuItem"
    ]

    private static func visibleTextSnippets(
        axApp: AXUIElement,
        bundleId: String,
        windowTitle: String,
        browserURL: String,
        excludedSubtreeRoot: AXUIElement?
    ) -> [String] {
        var snippets: [String] = []
        var seen = Set<String>()

        walkTree(element: axApp, depth: 0, maxDepth: 4) { element in
            guard snippets.count < 50 else { return false }
            if let excludedSubtreeRoot, CFEqual(element, excludedSubtreeRoot) {
                return false
            }

            var role: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            guard let roleStr = role as? String, snippetRoles.contains(roleStr) else { return true }

            let text: String? = {
                var value: AnyObject?
                if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
                   let str = value as? String, !str.isEmpty {
                    return str
                }
                var title: AnyObject?
                if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
                   let str = title as? String, !str.isEmpty {
                    return str
                }
                return nil
            }()

            guard let text,
                  text.count >= 3,
                  AccessibilityPlaceholderFilter.shouldKeepVisibleSnippet(
                    text,
                    bundleID: bundleId,
                    windowTitle: windowTitle,
                    browserURL: browserURL
                  )
            else { return true }
            let snippet = String(text.prefix(500))
            if seen.insert(snippet).inserted {
                snippets.append(snippet)
            }
            return true
        }

        return snippets
    }

    private static func focusedElement(axApp: AXUIElement) -> AXUIElement? {
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused,
              CFGetTypeID(element) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(element, to: AXUIElement.self)
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func copyBooleanAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        if let bool = value as? Bool {
            return bool
        }
        return (value as? NSNumber)?.boolValue
    }

    private static func copyElementAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func copyElementArrayAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> [AXUIElement]? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }

    private static func frame(for element: AXUIElement) -> CGRect? {
        guard let position = copyCGPointAttribute(
            element,
            kAXPositionAttribute as CFString
        ),
        let size = copyCGSizeAttribute(
            element,
            kAXSizeAttribute as CFString
        ),
        size.width > 0,
        size.height > 0 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func frameBucket(for element: AXUIElement) -> String? {
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

    private static func copyCGPointAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
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

    private static func copyCGSizeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
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

    private static func selectedRangeBucket(_ range: SelectionRange) -> String {
        let location = max(0, range.location / 80)
        let length = max(0, range.length / 20)
        return "\(location):\(length)"
    }

    private static func stableToken(_ value: String?) -> String? {
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

    // MARK: - AX tree traversal

    @discardableResult
    static func walkTree(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        visitor: (AXUIElement) -> Bool
    ) -> Bool {
        guard depth <= maxDepth else { return true }
        guard visitor(element) else { return false }

        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let childList = children as? [AXUIElement] else { return true }

        for child in childList.prefix(50) {
            if !walkTree(element: child, depth: depth + 1, maxDepth: maxDepth, visitor: visitor) {
                return false
            }
        }

        return true
    }
}
