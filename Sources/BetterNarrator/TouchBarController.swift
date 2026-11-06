import AppKit
import Combine

/// Puts Better Narrator's buttons on the Touch Bar, on the right-hand side,
/// even while another app is in front.
final class TouchBarController: NSObject, NSTouchBarDelegate {
    private enum ID {
        static let tray = NSTouchBarItem.Identifier("app.betternarrator.tray")
        static let copied = NSTouchBarItem.Identifier("app.betternarrator.copied")
        static let read = NSTouchBarItem.Identifier("app.betternarrator.read")
        static let time = NSTouchBarItem.Identifier("app.betternarrator.time")
        static let dismiss = NSTouchBarItem.Identifier("app.betternarrator.dismiss")
        static let back = NSTouchBarItem.Identifier("app.betternarrator.back")
        static let play = NSTouchBarItem.Identifier("app.betternarrator.play")
        static let forward = NSTouchBarItem.Identifier("app.betternarrator.forward")
        static let gap = NSTouchBarItem.Identifier.fixedSpaceSmall
    }

    var onRead: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let bar = NSTouchBar()
    private var trayItem: NSCustomTouchBarItem!
    private var presented = false

    private weak var session: ReadingSession?
    private var sessionSubs: Set<AnyCancellable> = []
    private var offerText: String?
    private var offerTimer: Timer?
    private var dismissArmed = false
    private var dismissTimer: Timer?

    private lazy var readButton: NSButton = {
        let b = NSButton(title: "Read", image: NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: nil)!,
                         target: self, action: #selector(readTapped))
        b.imagePosition = .imageLeading
        b.bezelColor = .systemBlue
        return b
    }()
    private lazy var copiedLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.textColor = .secondaryLabelColor
        l.font = .systemFont(ofSize: 13)
        l.lineBreakMode = .byTruncatingTail
        l.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        return l
    }()
    private lazy var timeLabel: NSTextField = {
        let l = NSTextField(labelWithString: "0:00")
        l.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        l.textColor = .secondaryLabelColor
        return l
    }()
    private lazy var dismissButton = NSButton(title: "Dismiss", target: self, action: #selector(dismissTapped))
    private lazy var backButton = symbolButton("gobackward.15", #selector(backTapped))
    private lazy var forwardButton = symbolButton("goforward.15", #selector(forwardTapped))
    private lazy var playButton: NSButton = {
        let b = NSButton(title: "Preparing…", target: self, action: #selector(playTapped))
        b.imagePosition = .imageLeading
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 128).isActive = true
        return b
    }()

    override init() {
        super.init()
        bar.delegate = self
        trayItem = NSCustomTouchBarItem(identifier: ID.tray)
        let trayButton = NSButton(image: NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Better Narrator")!,
                                  target: self, action: #selector(trayTapped))
        trayItem.view = trayButton
        BNSetControlStripItem(trayItem, true)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appSwitched),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    private func symbolButton(_ name: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)!, target: self, action: action)
        b.widthAnchor.constraint(equalToConstant: 72).isActive = true
        return b
    }

    // MARK: - What to show

    func show(session: ReadingSession?) {
        self.session = session
        sessionSubs.removeAll()
        if let session {
            session.$state.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshControls() } }.store(in: &sessionSubs)
            session.$readiness.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshControls() } }.store(in: &sessionSubs)
            session.$position
                .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
                .sink { [weak self] _ in self?.refreshTime() }.store(in: &sessionSubs)
        }
        rebuild()
    }

    /// Something was copied: offer a Read button for 10 seconds.
    func offer(text: String) {
        offerText = text
        let plain = ReadingDocument(markdown: text).plainText
        let preview = plain.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        copiedLabel.stringValue = preview.count > 48 ? String(preview.prefix(46)) + "…" : preview
        offerTimer?.invalidate()
        offerTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in self?.withdrawOffer() }
        rebuild()
    }

    func withdrawOffer() {
        offerTimer?.invalidate()
        offerText = nil
        rebuild()
    }

    var pendingOffer: String? { offerText }

    private func rebuild() {
        var ids: [NSTouchBarItem.Identifier] = [.flexibleSpace]
        if session != nil {
            if offerText != nil { ids += [ID.read, ID.gap, ID.gap] }
            ids += [ID.time, ID.gap, ID.dismiss, ID.gap, ID.gap, ID.back, ID.play, ID.forward]
        } else if offerText != nil {
            ids += [ID.copied, ID.gap, ID.read]
        }
        if ids.count == 1 {
            hide()
            return
        }
        bar.defaultItemIdentifiers = ids
        refreshControls()
        present()
    }

    func present() {
        guard bar.defaultItemIdentifiers.count > 1 else { return }
        if BNPresentSystemModalTouchBar(bar, ID.tray.rawValue) {
            presented = true
        } else {
            Log.info("Touch Bar takeover is not available on this macOS")
        }
    }

    func hide() {
        if presented { BNDismissSystemModalTouchBar(bar) }
        presented = false
    }

    func shutdown() {
        hide()
        BNSetControlStripItem(trayItem, false)
    }

    @objc private func appSwitched() {
        // The system can quietly put our bar away; bring it back while it matters.
        if presented { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.present() } }
    }

    // MARK: - Items

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        switch identifier {
        case ID.read: item.view = readButton
        case ID.copied: item.view = copiedLabel
        case ID.time: item.view = timeLabel
        case ID.dismiss: item.view = dismissButton
        case ID.back: item.view = backButton
        case ID.play: item.view = playButton
        case ID.forward: item.view = forwardButton
        default: return nil
        }
        return item
    }

    private func refreshControls() {
        guard let s = session else { return }
        switch s.state {
        case .preparing:
            playButton.title = "Preparing \(Int(s.readiness * 100))%"
            playButton.image = nil
            playButton.isEnabled = false
            playButton.bezelColor = nil
        case .ready:
            playButton.title = "Start"
            playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
            playButton.isEnabled = true
            playButton.bezelColor = .systemBlue
        case .playing, .buffering:
            playButton.title = s.state == .buffering ? "Catching up" : "Pause"
            playButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
            playButton.isEnabled = true
            playButton.bezelColor = nil
        case .paused:
            playButton.title = "Play"
            playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
            playButton.isEnabled = true
            playButton.bezelColor = .systemBlue
        case .finished:
            playButton.title = "Replay"
            playButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
            playButton.isEnabled = true
            playButton.bezelColor = nil
        }
        backButton.isEnabled = s.hasStarted || s.position > 0
        forwardButton.isEnabled = s.generated - s.position > 1
        refreshTime()
    }

    private func refreshTime() {
        guard let s = session else { return }
        timeLabel.stringValue = formatTime(s.position)
        forwardButton.isEnabled = s.generated - s.position > 1
    }

    // MARK: - Actions

    @objc private func readTapped() { onRead?() }
    @objc private func playTapped() { session?.togglePlay() }
    @objc private func backTapped() { session?.skip(by: -Settings.shared.skipSeconds) }
    @objc private func forwardTapped() { session?.skip(by: Settings.shared.skipSeconds) }
    @objc private func trayTapped() { present() }

    @objc private func dismissTapped() {
        if !dismissArmed {
            dismissArmed = true
            dismissButton.title = "Tap again to close"
            dismissButton.bezelColor = .systemRed
            dismissTimer?.invalidate()
            dismissTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.disarmDismiss() }
            return
        }
        disarmDismiss()
        onDismiss?()
    }

    private func disarmDismiss() {
        dismissArmed = false
        dismissTimer?.invalidate()
        dismissButton.title = "Dismiss"
        dismissButton.bezelColor = nil
    }
}
