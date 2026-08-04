import AppKit
import SwiftUI

/// Reusable key recorder for selecting a dictation trigger key.
struct HotkeyRecorderView: View {

    @Binding var trigger: HotkeyTrigger
    @Binding var alternateTriggers: [HotkeyTrigger]
    var warningsByTrigger: [HotkeyTrigger: String] = [:]
    var onChange: ((HotkeyTrigger, [HotkeyTrigger]) -> Void)?

    @State private var isCapturingPrimary = false

    private var choices: [HotkeyTrigger] {
        var list = HotkeyTrigger.presets
        if !list.contains(trigger) {
            list.append(trigger)
        }
        return list
    }

    var body: some View {
        Group {
            if isCapturingPrimary {
                KeycapRecordingPrompt {
                    isCapturingPrimary = false
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(choices, id: \.rawValue) { choice in
                        KeycapButton(
                            label: choice.displayName,
                            symbol: keycapSymbol(for: choice),
                            isSelected: trigger == choice,
                            warning: warningsByTrigger[choice]
                        ) {
                            apply(primary: choice, alternates: alternateTriggers)
                        }
                    }

                    Button {
                        isCapturingPrimary = true
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .medium))
                            Text("Other")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .frame(width: 110, height: 64)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(SettingsPalette.elevatedBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(SettingsPalette.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background {
            if isCapturingPrimary {
                HotkeyRecorderEventCatcher { newTrigger in
                    apply(primary: newTrigger, alternates: alternateTriggers)
                } onCancel: {
                    isCapturingPrimary = false
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isCapturingPrimary)
    }

    private func keycapSymbol(for trigger: HotkeyTrigger) -> String? {
        switch trigger {
        case .fn: "globe"
        case .rightOption: "option"
        case .custom: nil
        }
    }

    private func apply(primary: HotkeyTrigger, alternates: [HotkeyTrigger]) {
        let normalizedAlternates = HotkeyTrigger.deduplicated(alternates.filter { $0 != primary })

        let didChange = trigger != primary || alternateTriggers != normalizedAlternates
        isCapturingPrimary = false
        guard didChange else { return }

        trigger = primary
        alternateTriggers = normalizedAlternates
        onChange?(primary, normalizedAlternates)
    }
}

struct HotkeyModePicker: View {
    @Binding var mode: HotkeyMode
    var onChange: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(HotkeyMode.allCases, id: \.self) { option in
                ModeTile(
                    title: option.displayName,
                    icon: icon(for: option),
                    tooltip: tooltip(for: option),
                    isSelected: mode == option
                ) {
                    guard mode != option else { return }
                    mode = option
                    onChange?()
                }
            }
        }
    }

    private func icon(for mode: HotkeyMode) -> String {
        switch mode {
        case .hold: "hand.raised.fill"
        case .toggle: "hand.tap.fill"
        }
    }

    private func tooltip(for mode: HotkeyMode) -> String {
        switch mode {
        case .hold: "I prefer to hold, speak, and let go."
        case .toggle: "I prefer to tap, speak, and tap again to stop."
        }
    }
}

private struct ModeTile: View {
    let title: String
    let icon: String
    let tooltip: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 16)
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(borderColor, lineWidth: isSelected ? 1.5 : 1)
            )
            .shadow(color: .black.opacity(isSelected ? 0.0 : 0.04), radius: 1, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { isHovered = $0 }
        .scaleEffect(isHovered && !isSelected ? 1.01 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
    }

    private var fillColor: Color {
        if isSelected { return SettingsPalette.accentFill }
        if isHovered { return SettingsPalette.cardBackground }
        return SettingsPalette.elevatedBackground
    }

    private var borderColor: Color {
        isSelected ? SettingsPalette.accent : SettingsPalette.border
    }

    private var textColor: Color {
        isSelected ? SettingsPalette.accent : .primary
    }
}

private struct KeycapButton: View {
    let label: String
    let symbol: String?
    let isSelected: Bool
    var warning: String? = nil
    var onRemove: (() -> Void)? = nil
    let action: () -> Void

    @State private var isHovered = false
    @State private var showWarningPopover = false
    @State private var hoverToken = UUID()

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .medium))
                }
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(width: 110, height: 64)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(borderColor, lineWidth: isSelected ? 1.5 : 1)
            )
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.clear, .black.opacity(isSelected ? 0.0 : 0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                if onRemove != nil, isHovered {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary, SettingsPalette.cardBackground)
                        .padding(4)
                        .transition(.opacity)
                } else if warning != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(5)
                }
            }
            .shadow(color: .black.opacity(isSelected ? 0.0 : 0.04), radius: 1, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            guard warning != nil else { return }
            if hovering {
                let token = UUID()
                hoverToken = token
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    if hoverToken == token { showWarningPopover = true }
                }
            } else {
                hoverToken = UUID()
                showWarningPopover = false
            }
        }
        .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
        .popover(isPresented: $showWarningPopover, arrowEdge: .bottom) {
            if let warning {
                Text(warning)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(width: 240, alignment: .leading)
                    .background(Color.black)
            }
        }
    }

    private var fillColor: Color {
        if isSelected { return SettingsPalette.accentFill }
        if isHovered { return SettingsPalette.cardBackground }
        return SettingsPalette.elevatedBackground
    }

    private var borderColor: Color {
        isSelected ? SettingsPalette.accent : SettingsPalette.border
    }

    private var textColor: Color {
        isSelected ? SettingsPalette.accent : .primary
    }
}

private struct KeycapRecordingPrompt: View {
    let onCancel: () -> Void
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(pulse ? 0.4 : 1.0)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)

            Text("Press any key…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 64)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SettingsPalette.accentFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SettingsPalette.accent, lineWidth: 1.5)
        )
        .onAppear { pulse = true }
    }
}

struct HotkeyAlternateTriggersEditor: View {

    @Binding var trigger: HotkeyTrigger
    @Binding var alternateTriggers: [HotkeyTrigger]
    var onChange: ((HotkeyTrigger, [HotkeyTrigger]) -> Void)?

    @State private var isCapturingAlternate = false

    var body: some View {
        Group {
            if isCapturingAlternate {
                KeycapRecordingPrompt {
                    isCapturingAlternate = false
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(alternateTriggers, id: \.rawValue) { alternateTrigger in
                        KeycapButton(
                            label: alternateTrigger.displayName,
                            symbol: keycapSymbol(for: alternateTrigger),
                            isSelected: false,
                            onRemove: { removeAlternate(alternateTrigger) },
                            action: { removeAlternate(alternateTrigger) }
                        )
                    }

                    Button {
                        isCapturingAlternate = true
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .medium))
                            Text("Add")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .frame(width: 110, height: 64)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(SettingsPalette.elevatedBackground)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(SettingsPalette.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background {
            if isCapturingAlternate {
                HotkeyRecorderEventCatcher { newTrigger in
                    addAlternate(newTrigger)
                } onCancel: {
                    isCapturingAlternate = false
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isCapturingAlternate)
    }

    private func keycapSymbol(for trigger: HotkeyTrigger) -> String? {
        switch trigger {
        case .fn: "globe"
        case .rightOption: "option"
        case .custom: nil
        }
    }

    private func addAlternate(_ newTrigger: HotkeyTrigger) {
        defer { isCapturingAlternate = false }
        guard newTrigger != trigger else { return }

        var nextAlternates = alternateTriggers
        nextAlternates.append(newTrigger)
        apply(primary: trigger, alternates: nextAlternates)
    }

    private func removeAlternate(_ oldTrigger: HotkeyTrigger) {
        apply(
            primary: trigger,
            alternates: alternateTriggers.filter { $0 != oldTrigger }
        )
    }

    private func apply(primary: HotkeyTrigger, alternates: [HotkeyTrigger]) {
        let normalizedAlternates = HotkeyTrigger.deduplicated(alternates.filter { $0 != primary })

        let didChange = trigger != primary || alternateTriggers != normalizedAlternates
        guard didChange else { return }

        trigger = primary
        alternateTriggers = normalizedAlternates
        onChange?(primary, normalizedAlternates)
    }
}

// MARK: - Event catcher (NSViewRepresentable)

/// Invisible NSView that installs local event monitors while recording.
private struct HotkeyRecorderEventCatcher: NSViewRepresentable {

    let onCapture: (HotkeyTrigger) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(onCapture: onCapture, onCancel: onCancel)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onCapture = onCapture
        context.coordinator.onCancel = onCancel
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var onCapture: ((HotkeyTrigger) -> Void)?
        var onCancel: (() -> Void)?
        private var keyMonitor: Any?
        private var flagsMonitor: Any?

        func install(onCapture: @escaping (HotkeyTrigger) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel

            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 53 { // Escape
                    self.onCancel?()
                    return nil
                }
                // Skip Tab for accessibility
                if event.keyCode == 48 { return event }

                guard let trigger = self.triggerForKeyCode(event.keyCode) else {
                    NSSound.beep()
                    return nil
                }
                self.onCapture?(trigger)
                return nil
            }

            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self else { return event }
                let keyCode = event.keyCode

                // Only capture on key-down (flag added), not key-up
                guard self.isModifierDown(flags: event.modifierFlags, keyCode: keyCode) else {
                    return event
                }

                guard let trigger = self.triggerForKeyCode(keyCode) else {
                    NSSound.beep()
                    return nil
                }
                self.onCapture?(trigger)
                return nil
            }
        }

        func uninstall() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            keyMonitor = nil
            flagsMonitor = nil
        }

        deinit {
            uninstall()
        }

        private func triggerForKeyCode(_ keyCode: UInt16) -> HotkeyTrigger? {
            switch keyCode {
            case 63: return .fn
            case 61: return .rightOption
            default:
                guard HotkeyTrigger.isAllowedCustomKeyCode(keyCode) else {
                    return nil
                }
                return .custom(keyCode: keyCode)
            }
        }

        private func isModifierDown(flags: NSEvent.ModifierFlags, keyCode: UInt16) -> Bool {
            switch keyCode {
            case 54, 55: return flags.contains(.command)
            case 56, 60: return flags.contains(.shift)
            case 57:     return flags.contains(.capsLock)
            case 58, 61: return flags.contains(.option)
            case 59, 62: return flags.contains(.control)
            case 63:     return flags.contains(.function)
            default:     return false
            }
        }
    }
}
