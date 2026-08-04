import CryptoKit
import Foundation
import Sentry

struct SentryRuntimeConfiguration: Equatable {
    static let dsnInfoKey = "ResonantSentryDSN"
    static let projectInfoKey = "ResonantSentryProject"

    let dsn: String
    let project: String?

    static func from(infoDictionary: [String: Any]?) -> SentryRuntimeConfiguration? {
        guard let rawDSN = infoDictionary?[dsnInfoKey] as? String else {
            return nil
        }

        let dsn = rawDSN.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dsn.isEmpty else {
            return nil
        }

        let project = (infoDictionary?[projectInfoKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProject = project?.isEmpty == false ? project : nil

        return SentryRuntimeConfiguration(dsn: dsn, project: normalizedProject)
    }
}

@MainActor
final class SentryManager {

    static let shared = SentryManager()

    nonisolated private static let crashDiagnosticsDefaultsKey = "crashDiagnosticsEnabled"
    nonisolated private static let hipaaModeDefaultsKey = "hipaaMode"

    private let settings = SettingsManager.shared
    private var isConfigured = false
    private var hasLoggedMissingConfiguration = false

    private init() {}

    // MARK: - Setup

    func syncConfiguration(userId: String?, email: String?) {
        guard shouldEnableDiagnostics else {
            teardown()
            return
        }

        setupIfNeeded()
        guard shouldCaptureDiagnostics else { return }
        configureScope()

        let normalizedUserID = userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedUserID, !normalizedUserID.isEmpty {
            setUserContext(userId: normalizedUserID, email: normalizedEmail)
        } else {
            clearUserContext()
        }
    }

    func diagnosticContext(for error: Error, extras: [String: Any] = [:]) -> [String: Any] {
        SentryDiagnosticsSanitizer.errorContext(for: error, extras: extras)
    }

    private func setupIfNeeded() {
        guard !isConfigured else { return }
        guard let configuration = SentryRuntimeConfiguration.from(infoDictionary: Bundle.main.infoDictionary) else {
            if !hasLoggedMissingConfiguration {
                NSLog("Sentry diagnostics enabled but %@ is missing from the app bundle. Skipping runtime Sentry setup.", SentryRuntimeConfiguration.dsnInfoKey)
                hasLoggedMissingConfiguration = true
            }
            return
        }

        SentrySDK.start { options in
            options.dsn = configuration.dsn

            options.environment = AppRuntime.appEnvironment.sentryEnvironmentName

            #if DEBUG
            options.tracesSampleRate = 1.0
            #else
            options.tracesSampleRate = 0.2
            #endif

            options.attachStacktrace = true
            options.maxBreadcrumbs = 50
            options.enableAutoSessionTracking = true
            options.enableUncaughtNSExceptionReporting = true
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            options.sendDefaultPii = false
            options.beforeSend = { event in
                let defaults = UserDefaults(suiteName: AppRuntime.defaultsSuiteName) ?? .standard
                guard Self.shouldSendDiagnostics(using: defaults) else {
                    return nil
                }
                SentryDiagnosticsSanitizer.scrubEvent(event)
                if SentryDiagnosticsSanitizer.shouldIgnore(event) { return nil }
                return event
            }
        }

        isConfigured = true
        hasLoggedMissingConfiguration = false
        configureScope()
    }

    private func teardown() {
        guard isConfigured else { return }
        SentrySDK.close()
        isConfigured = false
    }

    // MARK: - User context

    func setUserContext(userId: String?, email: String?) {
        guard shouldCaptureDiagnostics else { return }
        let user = User()
        user.userId = userId
        // Hash email to avoid storing PII in Sentry.
        if let email, !email.isEmpty {
            user.email = sha256(email.lowercased()).prefix(12) + "@hashed"
        }
        SentrySDK.setUser(user)
    }

    func clearUserContext() {
        guard shouldCaptureDiagnostics else { return }
        let user = User()
        user.userId = AnalyticsIdentity.installID()
        SentrySDK.setUser(user)
    }

    // MARK: - Capture

    func captureException(_ error: Error, context: [String: Any] = [:]) {
        guard shouldCaptureDiagnostics else { return }
        guard !SentryDiagnosticsSanitizer.shouldDropCapturedException(error, context: context) else {
            return
        }
        SentrySDK.capture(error: error) { scope in
            for (key, value) in context {
                scope.setExtra(value: value, key: key)
            }
        }
    }

    func captureMessage(_ message: String, level: SentryLevel = .info, context: [String: Any] = [:]) {
        guard shouldCaptureDiagnostics else { return }
        let sanitizedMessage = SentryDiagnosticsSanitizer.sanitizeFreeformText(message)
        SentrySDK.capture(message: sanitizedMessage) { scope in
            scope.setLevel(level)
            for (key, value) in context {
                scope.setExtra(value: value, key: key)
            }
        }
    }

    // MARK: - Breadcrumbs

    func addBreadcrumb(category: String, message: String, level: SentryLevel = .info, data: [String: Any]? = nil) {
        guard shouldCaptureDiagnostics else { return }
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = message
        crumb.data = data
        SentrySDK.addBreadcrumb(crumb)
    }

    // Dictation
    func dictationStart(inputDevice: String? = nil) {
        addBreadcrumb(category: "dictation", message: "dictation_start", data: inputDevice.map { ["input_device": $0] })
    }

    func dictationEnd(duration: TimeInterval? = nil, wordCount: Int? = nil) {
        var data: [String: Any] = [:]
        if let duration { data["duration"] = duration }
        if let wordCount { data["word_count"] = wordCount }
        addBreadcrumb(category: "dictation", message: "dictation_end", data: data.isEmpty ? nil : data)
    }

    func dictationError(_ error: Error) {
        addBreadcrumb(
            category: "dictation",
            message: "dictation_error",
            level: .error,
            data: diagnosticContext(for: error)
        )
    }

    // Model
    func modelLoad(modelId: String) {
        addBreadcrumb(category: "model", message: "model_load", data: ["model_id": modelId])
    }

    func modelReady(modelId: String) {
        addBreadcrumb(category: "model", message: "model_ready", data: ["model_id": modelId])
    }

    func modelError(modelId: String, error: Error) {
        addBreadcrumb(
            category: "model",
            message: "model_error",
            level: .error,
            data: diagnosticContext(for: error, extras: ["model_id": modelId])
        )
    }

    // Download
    func downloadStart(modelId: String) {
        addBreadcrumb(category: "download", message: "download_start", data: ["model_id": modelId])
    }

    func downloadComplete(modelId: String) {
        addBreadcrumb(category: "download", message: "download_complete", data: ["model_id": modelId])
    }

    func downloadError(modelId: String, error: Error) {
        addBreadcrumb(
            category: "download",
            message: "download_error",
            level: .error,
            data: diagnosticContext(for: error, extras: ["model_id": modelId])
        )
    }

    // Microphone
    func microphoneSwitch(deviceName: String) {
        addBreadcrumb(category: "microphone", message: "microphone_switch", data: ["device_name": deviceName])
    }

    func microphoneError(_ error: Error) {
        addBreadcrumb(
            category: "microphone",
            message: "microphone_error",
            level: .error,
            data: diagnosticContext(for: error)
        )
    }

    func micCaptureStart(deviceName: String? = nil) {
        addBreadcrumb(category: "microphone", message: "mic_capture_start", data: deviceName.map { ["device_name": $0] })
    }

    func micCaptureError(_ error: Error) {
        addBreadcrumb(
            category: "microphone",
            message: "mic_capture_error",
            level: .error,
            data: diagnosticContext(for: error)
        )
    }

    // Hot Mic
    func hotMicToggled(enabled: Bool) {
        addBreadcrumb(category: "hot_mic", message: "hot_mic_toggled", data: ["enabled": enabled])
    }

    func hotMicWakeDetected() {
        addBreadcrumb(category: "hot_mic", message: "hot_mic_wake_detected")
    }

    func hotMicDispatch(wordCount: Int) {
        addBreadcrumb(category: "hot_mic", message: "hot_mic_dispatch", data: ["word_count": wordCount])
    }

    func hotMicError(_ error: Error) {
        addBreadcrumb(
            category: "hot_mic",
            message: "hot_mic_error",
            level: .error,
            data: diagnosticContext(for: error)
        )
    }

    // Cloud
    func cloudProcessingStart(path: String) {
        addBreadcrumb(category: "cloud", message: "cloud_processing_start", data: ["path": path])
    }

    func cloudProcessingEnd(path: String, durationMs: Int? = nil) {
        var data: [String: Any] = ["path": path]
        if let durationMs { data["duration_ms"] = durationMs }
        addBreadcrumb(category: "cloud", message: "cloud_processing_end", data: data)
    }

    func cloudProcessingError(path: String, error: Error) {
        addBreadcrumb(
            category: "cloud",
            message: "cloud_processing_error",
            level: .error,
            data: diagnosticContext(for: error, extras: ["path": path])
        )
    }

    // MARK: - Private

    private var shouldEnableDiagnostics: Bool {
        settings.crashDiagnosticsEnabled && !settings.hipaaMode
    }

    private var shouldCaptureDiagnostics: Bool {
        isConfigured && shouldEnableDiagnostics
    }

    nonisolated private static func shouldSendDiagnostics(using defaults: UserDefaults) -> Bool {
        let crashDiagnosticsEnabled = (defaults.object(forKey: crashDiagnosticsDefaultsKey) as? Bool) ?? false
        let hipaaModeEnabled = (defaults.object(forKey: hipaaModeDefaultsKey) as? Bool) ?? false
        return crashDiagnosticsEnabled && !hipaaModeEnabled
    }

    private func configureScope() {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let arch = cpuArchitecture()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let sttModel = settings.selectedModelId
        let sentryProject = SentryRuntimeConfiguration.from(infoDictionary: Bundle.main.infoDictionary)?.project
        let installId = AnalyticsIdentity.installID()
        let firstSeenAppVersion = AnalyticsIdentity.firstSeenAppVersion(currentAppVersion: appVersion)
        let normalizedUserId = settings.userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let authState = normalizedUserId?.isEmpty == false ? "identified" : "anonymous"

        SentrySDK.configureScope { scope in
            let user = User()
            user.userId = installId
            scope.setUser(user)

            scope.setTag(value: appVersion, key: "app_version")
            scope.setTag(value: buildNumber, key: "build_number")
            scope.setTag(value: "macOS", key: "platform")
            scope.setTag(value: arch, key: "arch")
            scope.setTag(value: osVersion, key: "os_version")
            scope.setTag(value: sttModel, key: "stt_model")
            scope.setTag(value: installId, key: "install_id")
            scope.setTag(value: authState, key: "auth_state")
            scope.setTag(value: firstSeenAppVersion, key: "first_seen_app_version")
            if let sentryProject {
                scope.setTag(value: sentryProject, key: "sentry_project")
            }
        }
    }

    private func sha256(_ input: String) -> String {
        guard let data = input.data(using: .utf8) else { return "unknown" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func cpuArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

// MARK: - Event filtering (nonisolated — runs on Sentry's background thread)

enum SentryDiagnosticsSanitizer {

    static let redactedPlaceholder = "[Redacted]"
    static let sensitiveKeys: Set<String> = [
        "prompt",
        "selected_text",
        "selectedtext",
        "text",
        "transcript",
        "transcription",
    ]
    static let sensitiveErrorKeys: Set<String> = [
        "error",
        "error_reason",
        "reason",
    ]
    static let quotedStringPattern = try! NSRegularExpression(pattern: #""[^"]{20,}""#)
    static let labelledSensitiveTextPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(transcript|transcription|selected\s*text|memo(?:\s+transcript)?|prompt)\s*:\s*(.+)"#
    )

    static let ignoredPatterns: [String] = [
        "EPIPE",
        "ECONNRESET",
        "ETIMEDOUT",
        "network connection was lost",
        "internet connection appears to be offline",
        "network connection was changed",
        "SSL error",
        "certificate",
        "kCFErrorDomainCFNetwork",
        "NSURLErrorDomain",
    ]

    static let ignoredOperationalPatterns: [String] = [
        "AudioRecorderError.finishFailed",
        "Cannot Record",
        "recording never started",
        "recording stopped before finalization",
        "recording file contained no audio",
        "recording file could not be read",
        "FluidAudio.ASRError",
        "invalidAudioData",
        "com.apple.coreaudio.avfaudio",
        "Code: -50",
    ]

    static func errorContext(for error: Error, extras: [String: Any] = [:]) -> [String: Any] {
        let nsError = error as NSError
        var context = extras
        context["error_type"] = String(reflecting: type(of: error))
        context["error_domain"] = nsError.domain
        context["error_code"] = nsError.code
        return context
    }

    static func scrubEvent(_ event: Event) {
        if var extras = event.extra {
            for key in extras.keys {
                extras[key] = scrubValue(extras[key], forKey: key)
            }
            event.extra = extras
        }

        if let exceptions = event.exceptions {
            for exception in exceptions {
                exception.value = sanitizeExceptionValue(exception.value)
            }
        }

        if let formattedMessage = event.message?.formatted {
            let scrubbedMessage = sanitizeFreeformText(formattedMessage)
            if scrubbedMessage != formattedMessage {
                event.message = SentryMessage(formatted: scrubbedMessage)
            }
        }

        if let breadcrumbs = event.breadcrumbs {
            for crumb in breadcrumbs {
                guard var data = crumb.data else { continue }
                var changed = false
                for key in data.keys {
                    let scrubbed = scrubValue(data[key], forKey: key)
                    if !valuesEqual(scrubbed, data[key]) {
                        data[key] = scrubbed
                        changed = true
                    }
                }
                if changed { crumb.data = data }
            }
        }
    }

    static func shouldIgnore(_ event: Event) -> Bool {
        let description = event.message?.formatted ?? ""
        let exceptionValues = event.exceptions?.compactMap { $0.value } ?? []
        let allText = ([description] + exceptionValues).joined(separator: " ").lowercased()

        return (ignoredPatterns + ignoredOperationalPatterns).contains {
            allText.contains($0.lowercased())
        }
    }

    static func shouldDropCapturedException(_ error: Error, context: [String: Any]) -> Bool {
        let source = context["source"] as? String
        let dictationBoundarySources: Set<String> = [
            "AppState.endDictation",
            "AppState.endMemo",
        ]

        if dictationBoundarySources.contains(source ?? "") {
            if case AudioRecorderError.finishFailed = error { return true }
            if case TranscriberError.notLoaded = error { return true }
            if case TranscriberError.notDownloaded = error { return true }
        }

        let nsError = error as NSError
        let text = [
            String(reflecting: type(of: error)),
            nsError.domain,
            nsError.localizedDescription,
        ].joined(separator: " ").lowercased()

        return ignoredOperationalPatterns.contains { text.contains($0.lowercased()) }
    }

    static func sanitizeFreeformText(_ input: String) -> String {
        sanitizeText(input, aggressivelyRedactFreeformText: false)
    }

    static func sanitizeExceptionValue(_ input: String) -> String {
        sanitizeText(input, aggressivelyRedactFreeformText: true)
    }

    private static func scrubValue(_ value: Any?, forKey key: String) -> Any? {
        guard let value else { return nil }
        guard let text = value as? String else { return value }

        let normalizedKey = key.lowercased()
        if sensitiveKeys.contains(normalizedKey) {
            return redactedPlaceholder
        }

        if sensitiveErrorKeys.contains(normalizedKey) {
            let sanitized = sanitizeExceptionValue(text)
            return sanitized == text ? sanitized : redactedPlaceholder
        }

        return sanitizeFreeformText(text)
    }

    private static func sanitizeText(_ input: String, aggressivelyRedactFreeformText: Bool) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return input }

        var scrubbed = redactLabelledSensitiveText(trimmed)
        scrubbed = redactLongQuotedStrings(scrubbed)

        if shouldRedactFreeformText(scrubbed, aggressively: aggressivelyRedactFreeformText) {
            return redactedPlaceholder
        }

        return scrubbed
    }

    private static func redactLongQuotedStrings(_ input: String) -> String {
        let range = NSRange(input.startIndex..., in: input)
        return quotedStringPattern.stringByReplacingMatches(in: input, range: range, withTemplate: "\"[Redacted]\"")
    }

    private static func redactLabelledSensitiveText(_ input: String) -> String {
        let range = NSRange(input.startIndex..., in: input)
        return labelledSensitiveTextPattern.stringByReplacingMatches(
            in: input,
            range: range,
            withTemplate: "$1: \(redactedPlaceholder)"
        )
    }

    private static func shouldRedactFreeformText(_ input: String, aggressively: Bool) -> Bool {
        if input.contains(redactedPlaceholder) {
            return false
        }

        if input.contains("\n"), input.count >= 80 {
            return true
        }

        let words = input.split(whereSeparator: \.isWhitespace)
        if words.count >= (aggressively ? 12 : 20) {
            return true
        }

        if input.count >= (aggressively ? 120 : 200) {
            return true
        }

        return false
    }

    private static func valuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case let (left as String, right as String):
            return left == right
        case let (left as NSNumber, right as NSNumber):
            return left == right
        default:
            return false
        }
    }
}
