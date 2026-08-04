import AppKit
import SwiftUI

/// Displays available screens and lets the user pin the notch to a specific display.
/// Compact layout designed to fit within the idle hover panel (480×130).
struct ScreenPickerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let displays = availableDisplays
        let pinnedId = appState.settingsManager.pinnedDisplayId

        VStack(spacing: 6) {
            if displays.isEmpty {
                Text("No displays found")
                    .font(.caption)
                    .foregroundStyle(.gray)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(displays, id: \.id) { display in
                            CompactScreenChip(
                                name: display.name,
                                isPinned: display.id == pinnedId
                            ) {
                                if display.id == pinnedId {
                                    appState.settingsManager.pinnedDisplayId = nil
                                } else {
                                    appState.settingsManager.pinnedDisplayId = display.id
                                }
                                appState.notchWindowManager?.repositionToTargetScreen()
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }

            Text(pinnedId == nil ? "Follows cursor" : "")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.gray.opacity(0.6))
                .frame(height: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct DisplayEntry {
        let id: Int
        let name: String
    }

    private var availableDisplays: [DisplayEntry] {
        NSScreen.screens.map { screen in
            DisplayEntry(
                id: Int(screen.displayID),
                name: screen.localizedName
            )
        }
    }
}

private struct CompactScreenChip: View {
    let name: String
    let isPinned: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isPinned ? "pin.fill" : "display")
                    .font(.system(size: 11, weight: isPinned ? .medium : .light))
                    .foregroundStyle(isPinned ? .white : .gray)

                Text(name)
                    .font(.system(size: 11, weight: isPinned ? .semibold : .regular))
                    .foregroundStyle(isPinned ? .white : .gray)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isPinned ? Color.white.opacity(0.14) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isPinned ? Color.white.opacity(0.5) : Color.white.opacity(0.15),
                        lineWidth: isPinned ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .clickableCursor()
    }
}
