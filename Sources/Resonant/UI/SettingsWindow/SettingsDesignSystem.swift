import SwiftUI

enum SettingsLayout {
    static let pageWidth: CGFloat = 760
    static let pageHorizontalPadding: CGFloat = 32
    static let pageVerticalPadding: CGFloat = 32
    static let pageTitleBottomPadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 28
    static let sectionHeaderSpacing: CGFloat = 10
    static let compactSpacing: CGFloat = 8
    static let controlMinHeight: CGFloat = 32
    static let cardPadding: CGFloat = 18
    static let insetPadding: CGFloat = 14
    static let cardRadius: CGFloat = 14
    static let insetRadius: CGFloat = 10
    static let rowMinHeight: CGFloat = 52
    static let rowHorizontalPadding: CGFloat = 16
    static let rowVerticalPadding: CGFloat = 12
    static let rowTextSpacing: CGFloat = 3
    static let rowControlWidth: CGFloat = 260
    static let rowIconWidth: CGFloat = 22
    static let codeBlockRadius: CGFloat = 6
    static let sidebarWidth: CGFloat = 220
    static let sidebarRowHeight: CGFloat = 30
}

enum SettingsTypography {
    static let pageTitle = Font.system(size: 22, weight: .semibold)
    static let pageSubtitle = Font.system(size: 13, weight: .regular)
    static let sectionTitle = Font.system(size: 15, weight: .semibold)
    static let sectionLabel = Font.system(size: 11, weight: .semibold)
    static let rowTitle = Font.system(size: 14, weight: .regular)
    static let rowDetail = Font.system(size: 12)
    static let cardTitle = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyLarge = Font.system(size: 14)
    static let metadata = Font.system(size: 11, weight: .medium)
    static let footer = Font.system(size: 11)
    static let metricValue = Font.system(size: 22, weight: .semibold)
    static let metricLabel = Font.system(size: 11, weight: .medium)
}

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(SettingsTypography.pageTitle)
                            .foregroundStyle(.primary)

                        if let subtitle {
                            Text(subtitle)
                                .font(SettingsTypography.pageSubtitle)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.bottom, SettingsLayout.pageTitleBottomPadding)

                    content
                }
                .frame(maxWidth: SettingsLayout.pageWidth, alignment: .leading)
                .padding(.horizontal, SettingsLayout.pageHorizontalPadding)
                .padding(.vertical, SettingsLayout.pageVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollContentBackground(.hidden)
            .background(SettingsPalette.windowBackground)
            .settingsScrollAnchorHandler(proxy: proxy)
        }
    }
}

struct SettingsPageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let accessory: Accessory

    init(
        title: String,
        subtitle: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(SettingsTypography.pageTitle)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(SettingsTypography.pageSubtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            accessory
        }
    }
}

struct ConsumerPrimaryButton: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @State private var isPressed = false

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.black.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: SettingsPalette.accent.opacity(isEnabled ? 0.25 : 0), radius: 4, x: 0, y: 2)
            .scaleEffect(isPressed ? 0.97 : 1.0)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1.0 : 0.5)
        .clickableCursor()
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private var fillColor: Color {
        if !isEnabled {
            return SettingsPalette.accent
        }
        return isHovered ? SettingsPalette.accent.opacity(0.88) : SettingsPalette.accent
    }
}

struct HelpIconButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("How it works")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isHovered ? SettingsPalette.accent : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(isHovered ? SettingsPalette.accentFill : SettingsPalette.elevatedBackground)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(isHovered ? SettingsPalette.accent : SettingsPalette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .help("Learn how this works")
        .onHover { isHovered = $0 }
    }
}

struct ConsumerTextFieldStyle: ViewModifier {
    var width: CGFloat = 340
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .padding(.horizontal, 14)
            .frame(width: width, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SettingsPalette.elevatedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isFocused ? SettingsPalette.accent : SettingsPalette.border,
                            lineWidth: isFocused ? 1.5 : 1)
            )
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
            .focused($isFocused)
    }
}

extension View {
    func consumerTextField(width: CGFloat = 340) -> some View {
        modifier(ConsumerTextFieldStyle(width: width))
    }
}

/// Inline text field used inside `SettingsTextFieldRow` / `SettingsSecureFieldRow`.
/// Replaces the native rounded-border style so the entire chrome focuses the
/// field — the native style had a hit area smaller than the visible bezel.
struct SettingsRowTextFieldStyle: ViewModifier {
    var maxWidth: CGFloat
    var isMonospaced: Bool
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            content
                .textFieldStyle(.plain)
                .font(isMonospaced ? .system(size: 12, design: .monospaced) : SettingsTypography.body)
                .padding(.horizontal, 10)
                .frame(maxWidth: maxWidth, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(SettingsPalette.elevatedBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isFocused ? SettingsPalette.accent : SettingsPalette.border,
                                lineWidth: isFocused ? 1.5 : 1)
                )
                .contentShape(Rectangle())
                .onTapGesture { isFocused = true }
                .focused($isFocused)
        }
    }
}

extension View {
    func settingsRowTextField(maxWidth: CGFloat, isMonospaced: Bool = false) -> some View {
        modifier(SettingsRowTextFieldStyle(maxWidth: maxWidth, isMonospaced: isMonospaced))
    }
}

struct SettingsBackLink: View {
    let target: SettingsTab
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Back to \(target.displayName)")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isHovered ? SettingsPalette.accent : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(isHovered ? SettingsPalette.accentFill : SettingsPalette.elevatedBackground)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(isHovered ? SettingsPalette.accent : SettingsPalette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .onHover { isHovered = $0 }
    }
}

struct SettingsSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(SettingsTypography.sectionLabel)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

struct SettingsCardSection<Content: View>: View {
    let title: String
    let footer: String?
    let headerAccessory: AnyView
    @ViewBuilder let content: Content

    init(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.headerAccessory = AnyView(EmptyView())
        self.content = content()
    }

    init<Accessory: View>(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder headerAccessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.headerAccessory = AnyView(headerAccessory())
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sectionHeaderSpacing) {
            HStack(spacing: 8) {
                Text(title)
                    .font(SettingsTypography.sectionTitle)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                headerAccessory
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous)
                    .fill(SettingsPalette.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous)
                    .stroke(SettingsPalette.border, lineWidth: 0.5)
            )
            .resonantShadow(.resting)

            if let footer {
                Text(footer)
                    .font(SettingsTypography.footer)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

struct SettingsSectionBody<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
            .padding(.vertical, SettingsLayout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(SettingsPalette.border)
            .frame(height: 0.5)
    }
}

struct SettingsPrimaryCard<Content: View>: View {
    let padding: CGFloat
    @ViewBuilder let content: Content

    init(
        padding: CGFloat = SettingsLayout.cardPadding,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous)
                    .fill(SettingsPalette.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous)
                    .stroke(SettingsPalette.border.opacity(0.12), lineWidth: 0.5)
            )
    }
}

struct SettingsInsetCard<Content: View>: View {
    let padding: CGFloat
    @ViewBuilder let content: Content

    init(
        padding: CGFloat = SettingsLayout.insetPadding,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: SettingsLayout.insetRadius, style: .continuous)
                    .fill(SettingsPalette.mutedCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsLayout.insetRadius, style: .continuous)
                    .stroke(SettingsPalette.border.opacity(0.14), lineWidth: 0.5)
            )
    }
}

struct SettingsDrillInRow: View {
    let title: String
    let detail: String
    let value: String?
    let systemImage: String
    let action: () -> Void

    @State private var isHovered = false

    init(
        title: String,
        detail: String,
        value: String? = nil,
        systemImage: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.value = value
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: SettingsLayout.rowIconWidth)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SettingsTypography.rowTitle)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(SettingsTypography.rowDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if let value {
                    Text(value)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
            .padding(.vertical, SettingsLayout.rowVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: SettingsLayout.rowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                Rectangle()
                    .fill(isHovered ? SettingsPalette.mutedCardBackground.opacity(0.7) : .clear)
            )
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct SettingsValueRow<Content: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let content: Content

    init(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: SettingsLayout.rowTextSpacing) {
                Text(title)
                    .font(SettingsTypography.rowTitle)
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(SettingsTypography.rowDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            content
                .controlSize(.regular)
        }
        .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
        .padding(.vertical, SettingsLayout.rowVerticalPadding)
        .frame(maxWidth: .infinity, minHeight: SettingsLayout.rowMinHeight, alignment: .leading)
    }
}

enum SettingsPickerPresentation {
    case menu
    case segmented
}

struct SettingsPickerRow<Selection: Hashable, Options: View>: View {
    let title: String
    let detail: String?
    @Binding var selection: Selection
    var presentation: SettingsPickerPresentation = .menu
    var controlWidth: CGFloat = SettingsLayout.rowControlWidth
    @ViewBuilder let options: Options

    init(
        _ title: String,
        detail: String? = nil,
        selection: Binding<Selection>,
        presentation: SettingsPickerPresentation = .menu,
        controlWidth: CGFloat = SettingsLayout.rowControlWidth,
        @ViewBuilder options: () -> Options
    ) {
        self.title = title
        self.detail = detail
        self._selection = selection
        self.presentation = presentation
        self.controlWidth = controlWidth
        self.options = options()
    }

    var body: some View {
        SettingsValueRow(title, detail: detail) {
            picker
        }
    }

    @ViewBuilder
    private var picker: some View {
        switch presentation {
        case .menu:
            Picker(title, selection: $selection) {
                options
            }
            .labelsHidden()
            .frame(maxWidth: controlWidth, alignment: .trailing)
        case .segmented:
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Picker(title, selection: $selection) {
                    options
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: controlWidth)
            }
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        SettingsValueRow(title, detail: detail) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.regular)
        }
    }
}

struct SettingsSliderRow: View {
    let title: String
    let detail: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var controlWidth: CGFloat = SettingsLayout.rowControlWidth
    var valueFormatter: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

    init(
        _ title: String,
        detail: String? = nil,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        controlWidth: CGFloat = SettingsLayout.rowControlWidth,
        valueFormatter: @escaping (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    ) {
        self.title = title
        self.detail = detail
        self._value = value
        self.range = range
        self.controlWidth = controlWidth
        self.valueFormatter = valueFormatter
    }

    var body: some View {
        SettingsValueRow(title, detail: detail) {
            HStack(spacing: 12) {
                Slider(value: $value, in: range) {
                    Text(title)
                }
                Text(valueFormatter(value))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .frame(maxWidth: controlWidth)
        }
    }
}

struct SettingsTextFieldRow: View {
    let title: String
    let detail: String?
    let placeholder: String
    @Binding var text: String
    var controlWidth: CGFloat = SettingsLayout.rowControlWidth
    var isMonospaced = false
    var onSubmit: (() -> Void)?

    init(
        _ title: String,
        detail: String? = nil,
        placeholder: String = "",
        text: Binding<String>,
        controlWidth: CGFloat = SettingsLayout.rowControlWidth,
        isMonospaced: Bool = false,
        onSubmit: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.placeholder = placeholder
        self._text = text
        self.controlWidth = controlWidth
        self.isMonospaced = isMonospaced
        self.onSubmit = onSubmit
    }

    var body: some View {
        SettingsValueRow(title, detail: detail) {
            textField
                .settingsRowTextField(maxWidth: controlWidth, isMonospaced: isMonospaced)
                .onSubmit {
                    onSubmit?()
                }
        }
    }

    @ViewBuilder
    private var textField: some View {
        if placeholder.isEmpty {
            TextField(title, text: $text)
        } else {
            TextField(title, text: $text, prompt: Text(placeholder))
        }
    }
}

struct SettingsSecureFieldRow: View {
    let title: String
    let detail: String?
    let placeholder: String
    @Binding var text: String
    var controlWidth: CGFloat = SettingsLayout.rowControlWidth
    var isMonospaced = false

    init(
        _ title: String,
        detail: String? = nil,
        placeholder: String = "",
        text: Binding<String>,
        controlWidth: CGFloat = SettingsLayout.rowControlWidth,
        isMonospaced: Bool = false
    ) {
        self.title = title
        self.detail = detail
        self.placeholder = placeholder
        self._text = text
        self.controlWidth = controlWidth
        self.isMonospaced = isMonospaced
    }

    var body: some View {
        SettingsValueRow(title, detail: detail) {
            SecureField(placeholder, text: $text)
                .settingsRowTextField(maxWidth: controlWidth, isMonospaced: isMonospaced)
        }
    }
}

struct SettingsButtonRow: View {
    let title: String
    let detail: String?
    let buttonTitle: String
    let systemImage: String?
    var role: ButtonRole?
    var isProminent = false
    let action: () -> Void

    init(
        _ title: String,
        detail: String? = nil,
        buttonTitle: String,
        systemImage: String? = nil,
        role: ButtonRole? = nil,
        isProminent: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.buttonTitle = buttonTitle
        self.systemImage = systemImage
        self.role = role
        self.isProminent = isProminent
        self.action = action
    }

    var body: some View {
        SettingsValueRow(title, detail: detail) {
            if isProminent {
                button
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .clickableCursor()
            } else {
                button
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .clickableCursor()
            }
        }
    }

    private var button: some View {
        Button(role: role, action: action) {
            if let systemImage {
                Label(buttonTitle, systemImage: systemImage)
            } else {
                Text(buttonTitle)
            }
        }
    }
}

struct SettingsTextEditorRow: View {
    let title: String
    let detail: String?
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: SettingsLayout.rowTextSpacing) {
                Text(title)
                    .font(SettingsTypography.rowTitle)
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(SettingsTypography.rowDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(SettingsTypography.body)
                    .frame(minHeight: minHeight, maxHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: SettingsLayout.insetRadius, style: .continuous)
                            .fill(SettingsPalette.elevatedBackground.opacity(0.75))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SettingsLayout.insetRadius, style: .continuous)
                            .stroke(SettingsPalette.border.opacity(0.18), lineWidth: 0.5)
                    )

                if text.isEmpty {
                    Text(placeholder)
                        .font(SettingsTypography.body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 12)
                        .padding(.top, 13)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, SettingsLayout.rowHorizontalPadding)
        .padding(.vertical, SettingsLayout.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsStatusPill: View {
    let title: String
    var detail: String? = nil
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }

            Text(title)
                .font(.system(size: 12, weight: .medium))

            if let detail {
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 0.5)
        )
    }
}

struct SettingsCodeBlock: View {
    let text: String
    var lineLimit: Int? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: SettingsLayout.codeBlockRadius, style: .continuous)
                    .fill(SettingsPalette.mutedCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsLayout.codeBlockRadius, style: .continuous)
                    .stroke(SettingsPalette.border.opacity(0.14), lineWidth: 0.5)
            )
    }
}

struct SettingsCallout: View {
    enum Tone {
        case info
        case warning
        case success
        case destructive

        var color: Color {
            switch self {
            case .info: SettingsPalette.infoText
            case .warning: .orange
            case .success: .green
            case .destructive: .red
            }
        }

        var icon: String {
            switch self {
            case .info: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .success: "checkmark.circle.fill"
            case .destructive: "exclamationmark.octagon.fill"
            }
        }
    }

    let title: String?
    let message: String
    var tone: Tone = .info
    var systemImage: String? = nil

    init(
        _ message: String,
        title: String? = nil,
        tone: Tone = .info,
        systemImage: String? = nil
    ) {
        self.title = title
        self.message = message
        self.tone = tone
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage ?? tone.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tone.color)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tone.color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tone.color.opacity(0.16), lineWidth: 1)
        )
    }
}

struct SettingsMetaPill: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color? = nil

    private var backgroundColor: Color {
        if let tint {
            return tint.opacity(0.10)
        }
        return SettingsPalette.elevatedBackground
    }

    private var borderColor: Color {
        if let tint {
            return tint.opacity(0.18)
        }
        return SettingsPalette.border.opacity(0.18)
    }

    private var foregroundColor: Color {
        tint ?? .secondary
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }

            Text(title)
                .lineLimit(1)
        }
        .font(SettingsTypography.metadata)
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
    }
}

struct SettingsMetricTile: View {
    let value: String
    let label: String
    var detail: String? = nil

    var body: some View {
        SettingsInsetCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(value)
                    .font(SettingsTypography.metricValue)
                    .foregroundStyle(.primary)
                    .monospacedDigit()

                Text(label)
                    .font(SettingsTypography.metricLabel)
                    .foregroundStyle(.secondary)

                if let detail {
                    Text(detail)
                        .font(SettingsTypography.metadata)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsLinearProgressBar: View {
    let value: Double
    var tint: Color = SettingsPalette.accent

    private var clampedValue: Double {
        min(max(value, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(SettingsPalette.border.opacity(0.18))

                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: max(geometry.size.width * clampedValue, clampedValue > 0 ? 6 : 0))
            }
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress \(Int((clampedValue * 100).rounded())) percent")
    }
}
