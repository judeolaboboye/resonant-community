import SwiftUI

/// Compact delivery-log surface for the Meetings → Advanced → Webhooks section.
/// Shows the last handful of webhook attempts so the user can confirm the queue
/// is healthy and replay a delivery that failed permanently.
struct MeetingWebhookDeliveryLogView: View {

    @Environment(AppState.self) private var appState
    @State private var entries: [MeetingWebhookOutbox.Envelope] = []
    @State private var isLoading = false
    @State private var refreshToken = UUID()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent deliveries")
                    .font(SettingsTypography.rowTitle)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh delivery log")
            }

            if isLoading && entries.isEmpty {
                Text("Loading…")
                    .font(SettingsTypography.rowDetail)
                    .foregroundStyle(.secondary)
            } else if entries.isEmpty {
                Text("No deliveries yet. Events will show up here after your next meeting recording.")
                    .font(SettingsTypography.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.prefix(10))) { entry in
                        deliveryRow(entry)
                        if entry.id != entries.prefix(10).last?.id {
                            Divider().padding(.leading, 8)
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.06))
                )
            }
        }
        .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
        .padding(.vertical, SettingsLayout.rowVerticalPadding)
        .task(id: refreshToken) {
            await refresh()
        }
    }

    @ViewBuilder
    private func deliveryRow(_ entry: MeetingWebhookOutbox.Envelope) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusBadge(entry.state)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.event)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                    if entry.attempts > 0 {
                        Text("· attempt \(entry.attempts)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if let code = entry.lastStatusCode {
                        Text("· HTTP \(code)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(detailLine(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if entry.state == .failed {
                Button("Retry") {
                    Task {
                        await appState.meetingWebhookSender.retryFromLog(
                            id: entry.id,
                            currentURL: appState.settingsManager.meetingWebhookURL
                        )
                        await refresh()
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func statusBadge(_ state: MeetingWebhookOutbox.State) -> some View {
        Circle().fill(color(for: state))
    }

    private func color(for state: MeetingWebhookOutbox.State) -> Color {
        switch state {
        case .delivered: return .green
        case .pending:   return .blue
        case .failed:    return .red
        case .dropped:   return .secondary
        }
    }

    private func detailLine(for entry: MeetingWebhookOutbox.Envelope) -> String {
        let reference = entry.lastAttemptAt ?? entry.createdAt
        let stamp = Self.timestampFormatter.string(from: reference)
        switch entry.state {
        case .delivered:
            return "Delivered · \(stamp)"
        case .pending:
            if let next = entry.nextAttemptAt, next > Date() {
                let retryStamp = Self.timestampFormatter.string(from: next)
                return "Retrying at \(retryStamp)" + (entry.lastError.map { " · \($0)" } ?? "")
            }
            return "Pending · \(stamp)"
        case .failed:
            return "Failed · \(stamp)" + (entry.lastError.map { " · \($0)" } ?? "")
        case .dropped:
            return "Dropped · \(stamp)" + (entry.lastError.map { " · \($0)" } ?? "")
        }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        entries = await MeetingWebhookOutbox.shared.recent(limit: 20)
    }
}
