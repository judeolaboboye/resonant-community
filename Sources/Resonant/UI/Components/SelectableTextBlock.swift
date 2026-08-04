import AppKit
import SwiftUI

struct SelectableTextBlock: NSViewRepresentable {
    let text: String
    let font: NSFont
    var textColor: NSColor = .labelColor
    var lineSpacing: CGFloat = 0

    func makeNSView(context: Context) -> SelectableTextView {
        let view = SelectableTextView()
        view.apply(
            text: text,
            font: font,
            textColor: textColor,
            lineSpacing: lineSpacing
        )
        return view
    }

    func updateNSView(_ nsView: SelectableTextView, context: Context) {
        nsView.apply(
            text: text,
            font: font,
            textColor: textColor,
            lineSpacing: lineSpacing
        )
    }
}

final class SelectableTextView: NSTextView {
    private var measuredWidth: CGFloat = 0

    init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)

        super.init(frame: .zero, textContainer: textContainer)

        drawsBackground = false
        isEditable = false
        isSelectable = true
        isRichText = false
        importsGraphics = false
        isHorizontallyResizable = false
        isVerticallyResizable = true
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        minSize = .zero
        textContainerInset = .zero
        backgroundColor = .clear

        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let minimumHeight = ceil(layoutManager.defaultLineHeight(for: font ?? .systemFont(ofSize: NSFont.systemFontSize)))
        let height = max(ceil(usedRect.height), minimumHeight)

        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)

        let width = max(newSize.width, 0)
        textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)

        guard abs(measuredWidth - width) > 0.5 else { return }
        measuredWidth = width
        invalidateIntrinsicContentSize()
    }

    func apply(text: String, font: NSFont, textColor: NSColor, lineSpacing: CGFloat) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = lineSpacing

        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle
            ]
        )

        textStorage?.setAttributedString(attributedText)
        invalidateIntrinsicContentSize()
    }
}
