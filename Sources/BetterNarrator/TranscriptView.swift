import AppKit
import Combine
import SwiftUI

/// Draws text backgrounds (the word highlight, inline code) as soft rounded shapes.
final class RoundedLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        color.setFill()
        for i in 0..<rectCount {
            let r = rectArray[i].insetBy(dx: -2, dy: 0.5)
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        }
    }
}

final class ReaderTextView: NSTextView {
    var onClickCharacter: ((Int) -> Void)?
    static let readableWidth: CGFloat = 680

    override func mouseDown(with event: NSEvent) {
        let before = selectedRange()
        super.mouseDown(with: event) // runs the selection loop until mouse up
        let after = selectedRange()
        guard after.length == 0, event.clickCount == 1 else { return }
        _ = before
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if index < (textStorage?.length ?? 0) { onClickCharacter?(index) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let side = max(36, (newSize.width - ReaderTextView.readableWidth) / 2)
        if abs(textContainerInset.width - side) > 0.5 {
            textContainerInset = NSSize(width: side, height: 34)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}

final class ReaderScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?
    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }
}

struct TranscriptView: NSViewRepresentable {
    @ObservedObject var session: ReadingSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> ReaderScrollView {
        let storage = NSTextStorage(attributedString: session.document.text)
        let layout = RoundedLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = ReaderTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 36, height: 34)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        textView.linkTextAttributes = [:]
        textView.onClickCharacter = { [weak session] i in session?.seek(toCharacter: i) }

        let scroll = ReaderScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 40, right: 0)
        scroll.onUserScroll = { [weak session] in
            guard let session, session.hasStarted else { return }
            if session.following { session.following = false }
        }
        context.coordinator.attach(textView: textView, scrollView: scroll)
        return scroll
    }

    func updateNSView(_ nsView: ReaderScrollView, context: Context) {}

    final class Coordinator {
        let session: ReadingSession
        weak var textView: ReaderTextView?
        weak var scrollView: ReaderScrollView?
        private var subs: Set<AnyCancellable> = []
        private var lastWord: NSRange?
        private var lastSegment: NSRange?

        init(session: ReadingSession) { self.session = session }

        func attach(textView: ReaderTextView, scrollView: ReaderScrollView) {
            self.textView = textView
            self.scrollView = scrollView
            session.$currentWord.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &subs)
            session.$currentSegmentRange.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &subs)
            session.$following.receive(on: RunLoop.main).sink { [weak self] f in
                if f { DispatchQueue.main.async { self?.scrollToCurrent(animated: true, force: true) } }
            }.store(in: &subs)
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: .main) { [weak self] _ in
                self?.scrollToCurrent(animated: false, force: false)
            }
        }

        private func refresh() {
            guard let lm = textView?.layoutManager else { return }
            let word = session.currentWord?.range
            let segment = session.currentSegmentRange
            if let r = lastSegment { lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r) }
            if let r = lastWord {
                lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
                lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: r)
            }
            if let r = segment {
                lm.addTemporaryAttribute(.backgroundColor, value: NSColor.systemBlue.withAlphaComponent(0.08), forCharacterRange: r)
            }
            if let r = word, r.length > 0 {
                lm.addTemporaryAttribute(.backgroundColor, value: NSColor.systemBlue, forCharacterRange: r)
                lm.addTemporaryAttribute(.foregroundColor, value: NSColor.white, forCharacterRange: r)
            }
            lastWord = word
            lastSegment = segment
            if session.following { scrollToCurrent(animated: true, force: false) }
        }

        /// Keeps the spoken word in the upper-middle of the page.
        func scrollToCurrent(animated: Bool, force: Bool) {
            guard let tv = textView, let scroll = scrollView, let lm = tv.layoutManager,
                  let container = tv.textContainer else { return }
            guard let range = session.currentWord?.range ?? session.currentSegmentRange ?? session.document.segments.first?.range else { return }
            let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.y += tv.textContainerInset.height
            let visible = scroll.contentView.bounds
            let comfortTop = visible.minY + visible.height * 0.12
            let comfortBottom = visible.minY + visible.height * 0.62
            if !force && rect.minY >= comfortTop && rect.maxY <= comfortBottom { return }
            let maxY = max(0, tv.frame.height - visible.height + scroll.contentInsets.bottom)
            let targetY = min(maxY, max(0, rect.minY - visible.height * 0.3))
            let target = NSPoint(x: 0, y: targetY)
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.35
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    scroll.contentView.animator().setBoundsOrigin(target)
                } completionHandler: {
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            } else {
                scroll.contentView.setBoundsOrigin(target)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }
}
