import AppKit
import SwiftUI

struct DispatchDebugTabView: View {
    @Environment(AppState.self) private var appState
    @State private var refreshID = UUID()
    @State private var showSensitive = false
    @State private var copiedMessage: String?

    private var logs: [DispatchLogEntry] {
        _ = refreshID
        return appState.dispatchLearningStore.recentLogs(limit: 40)
    }

    private var bindings: [DispatchLearningBinding] {
        _ = refreshID
        return appState.dispatchLearningStore.recentBindings(limit: 12)
    }

    private var activeTrial: DispatchTrialRecord? {
        _ = refreshID
        return appState.dispatchTrialStore.activeTrial
    }

    private var recentTrials: [DispatchTrialRecord] {
        _ = refreshID
        return Array(appState.dispatchTrialStore.recentTrials.prefix(8))
    }

    var body: some View {
        SettingsPage(
            title: "Dispatch Debug",
            subtitle: "Recent command routing, failures, target checks, and learned bindings."
        ) {
            controlsSection
            SettingsCardSection("Summary") {
                SettingsSectionBody {
                    summaryBand
                }
            }
            capabilityMatrix
            guidedTrials
            recentLogs
            learnedBindings
        }
    }

    private var controlsSection: some View {
        SettingsCardSection("Controls") {
            SettingsToggleRow(
                "Show sensitive text",
                detail: "Shows raw command text in this local debug view.",
                isOn: $showSensitive
            )

            SettingsRowDivider()
            SettingsButtonRow(
                "Replay fixtures",
                detail: "Copies runnable fixtures when sensitive text is shown; otherwise copies redacted fixtures.",
                buttonTitle: "Copy Fixtures",
                systemImage: "doc.on.doc"
            ) {
                copyReplayFixtures()
            }

            SettingsRowDivider()
            SettingsButtonRow(
                "Trial log",
                detail: "Copies the local dispatch_trials.jsonl path.",
                buttonTitle: "Copy Trial Log",
                systemImage: "list.clipboard"
            ) {
                copyTrialLogPath()
            }

            SettingsRowDivider()
            SettingsButtonRow(
                "Diagnostics",
                detail: "Refreshes Dispatch diagnostics.",
                buttonTitle: "Refresh",
                systemImage: "arrow.clockwise"
            ) {
                refreshID = UUID()
            }

            if let copiedMessage {
                SettingsRowDivider()
                SettingsSectionBody {
                    SettingsCallout(copiedMessage, tone: .success)
                }
            }
        }
    }

    private var capabilityMatrix: some View {
        SettingsCardSection(
            "Local Capabilities",
            footer: "What Dispatch can execute directly versus what is only prepared as a fallback."
        ) {
            SettingsSectionBody {
                HStack(spacing: 8) {
                    DispatchDebugPill(text: "available")
                    DispatchDebugPill(text: "degraded")
                    DispatchDebugPill(text: "blocked")
                    Spacer(minLength: 12)
                    Button {
                        copyCapabilityMatrix()
                    } label: {
                        Label("Copy Matrix", systemImage: "tablecells")
                    }
                    .buttonStyle(.bordered)
                    .help("Copy the Dispatch local capability matrix as JSON.")
                }
            }

            SettingsRowDivider()
            SettingsSectionBody {
                VStack(spacing: 8) {
                    ForEach(DispatchAppCapabilityCatalog.matrix, id: \.debugID) { entry in
                        DispatchCapabilityMatrixRow(entry: entry)
                    }
                }
            }
        }
    }

    private var guidedTrials: some View {
        SettingsCardSection(
            "Guided Trials",
            footer: "Start a scenario, say the prompt, then mark what actually happened."
        ) {
            SettingsButtonRow(
                "Scenario",
                detail: activeTrial == nil ? "No active trial." : "Complete the current trial before starting another.",
                buttonTitle: "Start Next",
                systemImage: "play.fill",
                isProminent: true
            ) {
                _ = appState.dispatchTrialStore.beginNextScenario()
                refreshID = UUID()
            }

            SettingsRowDivider()
            SettingsSectionBody {
            if let activeTrial {
                DispatchTrialActiveCard(
                    trial: activeTrial,
                    onOutcome: { outcome in
                        _ = appState.dispatchTrialStore.markOutcome(outcome: outcome)
                        refreshID = UUID()
                    }
                )
            } else {
                DispatchDebugEmptyRow(text: "No active trial. Start Next to get the next phrase to say.")
            }
            }

            if !recentTrials.isEmpty {
                SettingsRowDivider()
                SettingsSectionBody {
                    VStack(spacing: 8) {
                        ForEach(recentTrials) { trial in
                            DispatchTrialHistoryRow(trial: trial)
                        }
                    }
                }
            }
        }
    }

    private var summaryBand: some View {
        let failed = logs.filter { !$0.resultSuccess }.count
        let guardBlocks = logs.filter { $0.failureStage == .targetGuard }.count
        let fallbacks = logs.filter { $0.routeSource == .localFallback }.count
        let learned = logs.filter { $0.learnedBindingID != nil }.count

        return HStack(spacing: 10) {
            DispatchDebugMetric(title: "Logs", value: "\(logs.count)")
            DispatchDebugMetric(title: "Failures", value: "\(failed)")
            DispatchDebugMetric(title: "Guard blocks", value: "\(guardBlocks)")
            DispatchDebugMetric(title: "Fallbacks", value: "\(fallbacks)")
            DispatchDebugMetric(title: "Learned", value: "\(learned)")
        }
    }

    private var recentLogs: some View {
        SettingsCardSection("Recent Commands") {
            SettingsSectionBody {
            if logs.isEmpty {
                DispatchDebugEmptyRow(text: "No Dispatch commands have been logged yet.")
            } else {
                VStack(spacing: 8) {
                    ForEach(logs) { log in
                        DispatchDebugLogRow(log: log, showSensitive: showSensitive)
                    }
                }
            }
            }
        }
    }

    private var learnedBindings: some View {
        SettingsCardSection("Learned Bindings") {
            SettingsSectionBody {
            if bindings.isEmpty {
                DispatchDebugEmptyRow(text: "No reusable Dispatch bindings have been learned yet.")
            } else {
                VStack(spacing: 8) {
                    ForEach(bindings) { binding in
                        DispatchDebugBindingRow(binding: binding, showSensitive: showSensitive)
                    }
                }
            }
            }
        }
    }

    private func copyReplayFixtures() {
        let privacy: DispatchDiagnosticPrivacy = showSensitive ? .raw : .redacted
        let payload = DispatchRouteReplayFixtureBuilder.payload(
            from: logs,
            failuresOnly: true,
            privacy: privacy
        )
        let text = payload.objectValue?["json"]?.stringValue ?? "[]"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedMessage = privacy.isRedacted ? "Copied redacted fixtures" : "Copied runnable fixtures"
    }

    private func copyTrialLogPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(appState.dispatchTrialStore.logURL.path, forType: .string)
        copiedMessage = "Copied trial log path"
    }

    private func copyCapabilityMatrix() {
        let payload = DispatchAppCapabilityCatalog.matrixPayload()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let text: String
        if let data = try? encoder.encode(payload),
           let encoded = String(data: data, encoding: .utf8) {
            text = encoded
        } else {
            text = "{}"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedMessage = "Copied capability matrix"
    }
}

private struct DispatchTrialActiveCard: View {
    let trial: DispatchTrialRecord
    let onOutcome: (DispatchTrialOutcome) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(trial.prompt)
                        .font(.system(size: 17, weight: .semibold))
                    Text(expectedText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                DispatchDebugPill(text: trial.scenarioID ?? "ad hoc")
            }

            if !trial.preconditions.isEmpty {
                Text(trial.preconditions.joined(separator: " "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let verification = trial.automaticVerification {
                Text(verification.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(verification.verdict == .failed ? .orange : .secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                outcomeButton(.worked, systemImage: "checkmark")
                outcomeButton(.wrongTarget, systemImage: "scope")
                outcomeButton(.nothingHappened, systemImage: "exclamationmark.circle")
                outcomeButton(.badTranscript, systemImage: "waveform.badge.exclamationmark")
                outcomeButton(.tooSlow, systemImage: "clock")
                outcomeButton(.silentFailure, systemImage: "speaker.slash")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsPalette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(SettingsPalette.border.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var expectedText: String {
        guard let expected = trial.expected else {
            return "Ad-hoc trial. Outcome will still be logged."
        }
        return expected.observable
    }

    private func outcomeButton(_ outcome: DispatchTrialOutcome, systemImage: String) -> some View {
        Button {
            onOutcome(outcome)
        } label: {
            Label(outcome.displayName, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
    }
}

private struct DispatchTrialHistoryRow: View {
    let trial: DispatchTrialRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(trial.transcript ?? trial.prompt)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if let outcome = trial.userOutcome {
                DispatchDebugPill(text: outcome.rawValue)
            } else {
                DispatchDebugPill(text: trial.status.rawValue)
            }
            if let verification = trial.automaticVerification {
                DispatchDebugPill(text: verification.verdict.rawValue)
            }
            if let route = trial.route {
                DispatchDebugPill(text: route.source)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsPalette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(SettingsPalette.border.opacity(0.16), lineWidth: 0.5)
        )
    }

    private var subtitle: String {
        let route = trial.route?.routeID ?? "no route"
        let result = trial.resultSummary ?? "no result"
        let labels = trial.failureLabels.map(\.rawValue).joined(separator: ", ")
        let base = labels.isEmpty ? "\(route) -> \(result)" : "\(route) -> \(result) -> \(labels)"
        guard let verification = trial.automaticVerification else {
            return base
        }
        return "\(base) -> \(verification.summary)"
    }

    private var statusColor: Color {
        if trial.userOutcome == .worked {
            return .green
        }
        if let outcome = trial.userOutcome, outcome != .worked {
            return .orange
        }
        if trial.automaticVerification?.verdict == .passed || trial.resultSuccess == true {
            return .green
        }
        if trial.automaticVerification?.verdict == .failed {
            return .orange
        }
        if trial.resultSuccess == false || !trial.failureLabels.isEmpty {
            return .orange
        }
        return .secondary
    }
}

private struct DispatchDebugMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsPalette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(SettingsPalette.border.opacity(0.18), lineWidth: 0.5)
        )
    }
}

private struct DispatchCapabilityMatrixRow: View {
    let entry: DispatchAppCapabilityCatalog.MatrixEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("\(entry.app.rawValue.capitalized) / \(entry.operation.replacingOccurrences(of: "_", with: " "))")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    DispatchDebugPill(text: entry.localCapability.rawValue)
                }

                Text(entry.notes)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 6) {
                    DispatchDebugPill(text: entry.preferredStrategy.rawValue)
                    DispatchDebugPill(text: entry.verificationStrategy.rawValue)
                }
                Text(detailLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsPalette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(SettingsPalette.border.opacity(0.16), lineWidth: 0.5)
        )
    }

    private var detailLine: String {
        var details: [String] = []
        if entry.requiresAPI {
            details.append("API required")
        }
        if entry.requiresActiveTarget {
            details.append("active target required")
        }
        if let fallback = entry.fallback {
            details.append("fallback: \(fallback)")
        }
        return details.isEmpty ? "direct local execution" : details.joined(separator: " - ")
    }
}

private extension DispatchAppCapabilityCatalog.MatrixEntry {
    var debugID: String {
        "\(app.rawValue).\(operation)"
    }
}

private struct DispatchDebugLogRow: View {
    let log: DispatchLogEntry
    let showSensitive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                statusDot

                VStack(alignment: .leading, spacing: 3) {
                    Text(commandText)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                DispatchDebugPill(text: log.routeSource?.rawValue ?? "unknown")
                if let failureStage = log.failureStage {
                    DispatchDebugPill(text: failureStage.rawValue)
                }
            }

            if let reason = routeReason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let check = log.targetCheck {
                Text(targetCheckText(check))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(check.required && check.summary != nil ? .orange : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsPalette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(SettingsPalette.border.opacity(0.16), lineWidth: 0.5)
        )
    }

    private var commandText: String {
        showSensitive ? log.command : DispatchDiagnosticRedactor.redactCommand(log.command, privacy: .redacted)
    }

    private var subtitle: String {
        let action = log.actionSummary ?? DispatchLearningInspector.actionSummary(log.action)
        let result = showSensitive
            ? log.resultSummary
            : DispatchDiagnosticRedactor.redactDiagnosticText(log.resultSummary, privacy: .redacted)
        return "\(log.routeCard.title) -> \(action) -> \(result)"
    }

    private var routeReason: String? {
        guard let reason = log.routeReason else { return nil }
        return showSensitive
            ? reason
            : DispatchDiagnosticRedactor.redactDiagnosticText(reason, privacy: .redacted)
    }

    private var statusDot: some View {
        Circle()
            .fill(log.resultSuccess ? Color.green : Color.orange)
            .frame(width: 8, height: 8)
    }

    private func targetCheckText(_ check: DispatchTargetCheck) -> String {
        let score = check.matchScore.map { String(format: "%.2f", $0) } ?? "n/a"
        let minimum = check.minimumScore.map { String(format: "%.2f", $0) } ?? "n/a"
        return "target score \(score) / \(minimum) - \(check.summary ?? "checked")"
    }
}

private struct DispatchDebugBindingRow: View {
    let binding: DispatchLearningBinding
    let showSensitive: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(commandPattern)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(binding.routeCard.title) -> \(actionSummary)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            DispatchDebugPill(text: String(format: "%.0f%%", binding.confidence * 100))
            DispatchDebugPill(text: "\(binding.successCount) ok / \(binding.failureCount) fail")
            DispatchDebugPill(text: binding.isUsable ? "usable" : "held")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsPalette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(SettingsPalette.border.opacity(0.16), lineWidth: 0.5)
        )
    }

    private var commandPattern: String {
        showSensitive
            ? binding.commandPattern
            : DispatchDiagnosticRedactor.redactPattern(binding.commandPattern, privacy: .redacted)
    }

    private var actionSummary: String {
        DispatchLearningInspector.actionSummary(
            binding.action,
            privacy: showSensitive ? .raw : .redacted
        )
    }
}

private struct DispatchDebugPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(SettingsPalette.mutedCardBackground)
            )
    }
}

private struct DispatchDebugEmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(SettingsPalette.cardBackground)
            )
    }
}
