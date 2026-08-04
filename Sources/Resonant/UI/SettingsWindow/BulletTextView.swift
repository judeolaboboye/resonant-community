import AppKit
import SwiftUI

/// Plain-text `NSTextView` wrapper with bullet continuation + Tab indentation.
/// SwiftUI's `TextEditor` doesn't expose the keystroke hooks we need to continue
/// a "- " or "• " prefix when the user presses Return, and was also failing to
/// reliably take first-responder inside the meeting detail panel.
struct BulletTextView: NSViewRepresentable {
    @Binding var text: String
    var minHeight: CGFloat = 100
    var maintainsBulletList = false

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder

        let textView = BulletAwareTextView()
        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: minHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let clamped = min(selection.location, textView.string.count)
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BulletTextView
        weak var textView: NSTextView?

        init(_ parent: BulletTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard parent.maintainsBulletList,
                  let tv = notification.object as? NSTextView,
                  tv.string.isEmpty else { return }
            insertInitialBullet(in: tv)
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard parent.maintainsBulletList,
                  textView.string.isEmpty,
                  let replacementString,
                  !replacementString.isEmpty else { return true }

            let bulletized = Self.bulletizedReplacement(replacementString)
            guard bulletized != replacementString else { return true }
            textView.replaceCharacters(in: affectedCharRange, with: bulletized)
            textView.setSelectedRange(NSRange(location: affectedCharRange.location + (bulletized as NSString).length, length: 0))
            textView.didChangeText()
            return false
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                return handleReturn(textView)
            case #selector(NSResponder.insertTab(_:)):
                return handleIndent(textView, outdent: false)
            case #selector(NSResponder.insertBacktab(_:)):
                return handleIndent(textView, outdent: true)
            default:
                return false
            }
        }

        private func handleReturn(_ tv: NSTextView) -> Bool {
            let selection = tv.selectedRange()
            let ns = tv.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
            let upToCaretLength = max(0, selection.location - lineRange.location)
            let linePrefix = ns.substring(with: NSRange(location: lineRange.location, length: upToCaretLength))

            guard let match = Self.bulletRegex.firstMatch(
                in: linePrefix,
                range: NSRange(location: 0, length: (linePrefix as NSString).length)
            ) else { return false }

            let indent = (linePrefix as NSString).substring(with: match.range(at: 1))
            let bullet = (linePrefix as NSString).substring(with: match.range(at: 2))
            let afterBullet = (linePrefix as NSString).substring(from: match.range.length)
            let isEmptyBullet = afterBullet.trimmingCharacters(in: .whitespaces).isEmpty
                && Self.restOfLineIsEmpty(ns: ns, lineRange: lineRange, caret: selection.location)

            if isEmptyBullet {
                let replaceRange = NSRange(location: lineRange.location, length: upToCaretLength)
                guard tv.shouldChangeText(in: replaceRange, replacementString: "") else { return false }
                tv.replaceCharacters(in: replaceRange, with: "")
                tv.didChangeText()
                return true
            }

            let continuation = "\n\(indent)\(bullet) "
            guard tv.shouldChangeText(in: selection, replacementString: continuation) else { return false }
            tv.replaceCharacters(in: selection, with: continuation)
            tv.didChangeText()
            return true
        }

        private func insertInitialBullet(in tv: NSTextView) {
            let range = NSRange(location: 0, length: 0)
            guard tv.shouldChangeText(in: range, replacementString: "- ") else { return }
            tv.replaceCharacters(in: range, with: "- ")
            tv.setSelectedRange(NSRange(location: 2, length: 0))
            tv.didChangeText()
        }

        private func handleIndent(_ tv: NSTextView, outdent: Bool) -> Bool {
            let selection = tv.selectedRange()
            let ns = tv.string as NSString
            let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
            let prefix = ns.substring(with: NSRange(location: lineRange.location, length: min(lineRange.length, max(0, selection.location - lineRange.location))))

            guard Self.bulletRegex.firstMatch(
                in: prefix,
                range: NSRange(location: 0, length: (prefix as NSString).length)
            ) != nil else { return false }

            if outdent {
                if ns.substring(with: NSRange(location: lineRange.location, length: min(2, lineRange.length))) == "  " {
                    let removeRange = NSRange(location: lineRange.location, length: 2)
                    guard tv.shouldChangeText(in: removeRange, replacementString: "") else { return true }
                    tv.replaceCharacters(in: removeRange, with: "")
                    tv.didChangeText()
                }
                return true
            } else {
                let insertRange = NSRange(location: lineRange.location, length: 0)
                guard tv.shouldChangeText(in: insertRange, replacementString: "  ") else { return true }
                tv.replaceCharacters(in: insertRange, with: "  ")
                tv.didChangeText()
                return true
            }
        }

        private static let bulletRegex: NSRegularExpression = {
            try! NSRegularExpression(pattern: "^([ \\t]*)([-•*])[ \\t]")
        }()

        private static func bulletizedReplacement(_ replacement: String) -> String {
            let lines = replacement.components(separatedBy: .newlines)
            let bulletized = lines.map { line -> String in
                if line.isEmpty { return "- " }
                if line.range(of: #"^[ \t]*[-•*][ \t]"#, options: .regularExpression) != nil {
                    return line
                }
                return "- \(line)"
            }
            return bulletized.joined(separator: "\n")
        }

        private static func restOfLineIsEmpty(ns: NSString, lineRange: NSRange, caret: Int) -> Bool {
            let trailingLength = max(0, (lineRange.location + lineRange.length) - caret)
            guard trailingLength > 0 else { return true }
            let trailing = ns.substring(with: NSRange(location: caret, length: trailingLength))
            return trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

private final class BulletAwareTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}
