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
        // Copies of the Control Strip's own buttons, shown on the left.
        static let cat = NSTouchBarItem.Identifier("app.betternarrator.cat")
        static let wheel = NSTouchBarItem.Identifier("app.betternarrator.wheel")
        static let window = NSTouchBarItem.Identifier("app.betternarrator.window")
        static let previous = NSTouchBarItem.Identifier("app.betternarrator.sys.previous")
        static let media = NSTouchBarItem.Identifier("app.betternarrator.sys.media")
        static let next = NSTouchBarItem.Identifier("app.betternarrator.sys.next")
        static let mute = NSTouchBarItem.Identifier("app.betternarrator.sys.mute")
        static let volume = NSTouchBarItem.Identifier("app.betternarrator.sys.volume")
        static let brightness = NSTouchBarItem.Identifier("app.betternarrator.sys.brightness")
        static let close = NSTouchBarItem.Identifier("app.betternarrator.sys.close")
        static let slider = NSTouchBarItem.Identifier("app.betternarrator.sys.slider")
    }

    /// Which system slider is open in place of the strip, if any.
    private enum Expanded { case volume, brightness }
    private var expanded: Expanded?
    private var collapseTimer: Timer?

    var onRead: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onToggleWindow: (() -> Void)?

    private let bar = NSTouchBar()
    private var presented = false
    private var processing = false
    private var catView: NSView?
    /// A live copy of Touch Bar Pet's cat, because macOS shows only one app's bar at a time.
    private let cat = CatMirrorView()
    private var settingsSub: AnyCancellable?

    private weak var session: ReadingSession?
    private var sessionSubs: Set<AnyCancellable> = []
    private var offerText: String?
    private var offerTimer: Timer?

    private lazy var readButton: NSButton = {
        let b = NSButton(title: "Read", image: NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: nil)!,
                         target: self, action: #selector(readTapped))
        b.imagePosition = .imageLeading
        b.widthAnchor.constraint(equalToConstant: 104).isActive = true
        return b
    }()
    private lazy var wheel: SpeedWheelView = {
        let w = SpeedWheelView(touchBar: true)
        w.value = Settings.shared.speed
        w.onChange = { Settings.shared.speed = $0 }
        w.widthAnchor.constraint(equalToConstant: 190).isActive = true
        return w
    }()
    private lazy var windowButton = symbolButton("doc.plaintext", #selector(windowTapped), width: 44)
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
    private lazy var dismissButton = symbolButton("xmark", #selector(dismissTapped), width: 44)
    private lazy var backButton = symbolButton("gobackward.15", #selector(backTapped), width: 50)
    private lazy var forwardButton = symbolButton("goforward.15", #selector(forwardTapped), width: 50)
    private lazy var playButton: NSButton = {
        let b = NSButton(title: "", target: self, action: #selector(playTapped))
        b.imagePosition = .imageOnly
        b.widthAnchor.constraint(equalToConstant: 64).isActive = true
        return b
    }()

    override init() {
        super.init()
        bar.delegate = self
        cat.isPaused = true
        cat.onAvailabilityChange = { [weak self] available in
            guard let self else { return }
            self.setCat(available ? self.cat : nil)
        }
        if CatMirrorView.petIsRunning { catView = cat }
        settingsSub = Settings.shared.$speed.sink { [weak self] s in
            DispatchQueue.main.async { self?.wheel.value = s }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appSwitched),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    private func symbolButton(_ name: String, _ action: Selector, width: CGFloat = 60) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)!, target: self, action: action)
        b.widthAnchor.constraint(equalToConstant: width).isActive = true
        return b
    }

    private var systemStrip: [NSTouchBarItem.Identifier] {
        switch expanded {
        case .volume?, .brightness?:
            return [ID.close, ID.slider]
        case nil:
            return [ID.previous, ID.media, ID.next, ID.gap, ID.mute, ID.volume, ID.brightness]
        }
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

    /// Something was copied or highlighted: offer a Read button for 10 seconds.
    func offer(preview raw: String) {
        offerText = raw
        let preview = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        copiedLabel.stringValue = preview.count > 48 ? String(preview.prefix(46)) + "…" : preview
        offerTimer?.invalidate()
        offerTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in self?.withdrawOffer() }
        rebuild()
    }

    var onOfferExpired: (() -> Void)?

    func withdrawOffer() {
        offerTimer?.invalidate()
        guard offerText != nil else { return }
        offerText = nil
        onOfferExpired?()
        rebuild()
    }

    /// Read was pressed: the far-right button says "Processing…" until talking starts.
    func setProcessing(_ on: Bool) {
        guard processing != on else { return }
        processing = on
        rebuild()
    }

    /// The live cat from Touch Bar Pet, shown at the far left. Nil when the pet isn't running.
    func setCat(_ view: NSView?) {
        catView = view
        bar.defaultItemIdentifiers = []
        rebuild()
    }

    /// Shows whether the reading window is open.
    func setWindowShown(_ shown: Bool) {
        windowButton.image = NSImage(systemSymbolName: shown ? "doc.plaintext.fill" : "doc.plaintext", accessibilityDescription: nil)
        windowButton.bezelColor = shown ? .systemBlue : nil
    }

    private func rebuild() {
        // Read always sits at the far right, so it never moves under your finger.
        var ids: [NSTouchBarItem.Identifier] = (catView != nil ? [ID.cat] : []) + systemStrip + [.flexibleSpace]
        if session != nil {
            ids += [ID.wheel, ID.time, ID.window, ID.dismiss, ID.back, ID.play, ID.forward, ID.gap, ID.read]
        } else if offerText != nil || processing {
            ids += [ID.copied, ID.gap, ID.read]
        }
        if session == nil && offerText == nil && !processing {
            hide()
            return
        }
        if bar.defaultItemIdentifiers != ids { bar.defaultItemIdentifiers = ids }
        refreshRead()
        refreshControls()
        if !presented { present() }
    }

    private func refreshRead() {
        readButton.title = processing ? "Processing…" : "Read"
        readButton.image = processing ? nil : NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: nil)
        let canPress = !processing && offerText != nil
        readButton.isEnabled = canPress
        readButton.bezelColor = canPress ? .systemBlue : nil
        if processing || offerText == nil { copiedLabel.stringValue = processing ? "" : copiedLabel.stringValue }
    }

    func present() {
        guard bar.defaultItemIdentifiers.count > 1 else { return }
        cat.isPaused = false
        if BNPresentSystemModalTouchBar(bar, ID.tray.rawValue) {
            presented = true
        } else {
            Log.info("Touch Bar takeover is not available on this macOS")
        }
    }

    func hide() {
        if presented { BNDismissSystemModalTouchBar(bar) }
        presented = false
        cat.isPaused = true
    }

    func shutdown() {
        hide()
    }

    @objc private func appSwitched() {
        // The system can quietly put our bar away; bring it back while it matters.
        if presented { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.present() } }
    }

    // MARK: - Items

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        if let system = makeSystemItem(identifier) { return system }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.visibilityPriority = .high
        switch identifier {
        case ID.read: item.view = readButton
        case ID.wheel: item.view = wheel
        case ID.window: item.view = windowButton
        case ID.cat:
            guard let catView else { return nil }
            item.view = catView
            item.visibilityPriority = .normal
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

    // MARK: - Control Strip copies

    private func makeSystemItem(_ identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        switch identifier {
        case ID.previous:
            item.view = symbolButton("backward.fill", #selector(previousTapped), width: 44)
            item.visibilityPriority = .low
        case ID.media: item.view = symbolButton("playpause.fill", #selector(mediaTapped), width: 44)
        case ID.next:
            item.view = symbolButton("forward.fill", #selector(nextTapped), width: 44)
            item.visibilityPriority = .low
        case ID.mute:
            item.view = symbolButton("speaker.slash.fill", #selector(muteTapped), width: 44)
            item.visibilityPriority = .low
        case ID.volume: item.view = symbolButton("speaker.wave.2.fill", #selector(volumeTapped), width: 44)
        case ID.brightness: item.view = symbolButton("sun.max.fill", #selector(brightnessTapped), width: 44)
        case ID.close: item.view = symbolButton("xmark", #selector(collapseSlider), width: 44)
        case ID.slider:
            let slider = NSSliderTouchBarItem(identifier: identifier)
            let isVolume = expanded == .volume
            slider.slider.minValue = 0
            slider.slider.maxValue = 1
            slider.slider.doubleValue = Double(isVolume ? SystemControls.volume : SystemControls.brightness)
            slider.minimumValueAccessory = NSSliderAccessory(image: NSImage(systemSymbolName: isVolume ? "speaker.fill" : "sun.min.fill", accessibilityDescription: nil)!)
            slider.maximumValueAccessory = NSSliderAccessory(image: NSImage(systemSymbolName: isVolume ? "speaker.wave.3.fill" : "sun.max.fill", accessibilityDescription: nil)!)
            slider.slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
            slider.target = self
            slider.action = #selector(sliderMoved(_:))
            slider.visibilityPriority = .normal
            return slider
        default:
            return nil
        }
        return item
    }

    @objc private func previousTapped() { SystemControls.press(.previous) }
    @objc private func mediaTapped() { SystemControls.press(.play) }
    @objc private func nextTapped() { SystemControls.press(.next) }
    @objc private func muteTapped() { SystemControls.isMuted.toggle() }
    @objc private func volumeTapped() { expand(.volume) }
    @objc private func brightnessTapped() { expand(.brightness) }

    func showVolumeSlider() { expand(.volume) }

    private func expand(_ which: Expanded) {
        expanded = which
        bar.defaultItemIdentifiers = []  // force the slider to be rebuilt with fresh values
        rebuild()
        scheduleCollapse()
    }

    @objc private func collapseSlider() {
        collapseTimer?.invalidate()
        expanded = nil
        rebuild()
    }

    private func scheduleCollapse() {
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in self?.collapseSlider() }
    }

    @objc private func sliderMoved(_ sender: NSSliderTouchBarItem) {
        let v = Float(sender.slider.doubleValue)
        if expanded == .volume { SystemControls.volume = v } else { SystemControls.brightness = v }
        scheduleCollapse()
    }

    private func refreshControls() {
        guard let s = session else { return }
        if processing && s.state != .preparing && s.state != .ready {
            processing = false
            refreshRead()
        }
        func symbol(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }
        playButton.isEnabled = s.state != .preparing
        playButton.imagePosition = s.state == .preparing ? .noImage : .imageOnly
        playButton.title = s.state == .preparing ? "\(Int(s.readiness * 100))%" : ""
        switch s.state {
        case .preparing:
            playButton.image = nil
            playButton.bezelColor = nil
        case .ready, .paused:
            playButton.image = symbol("play.fill")
            playButton.bezelColor = .systemBlue
        case .playing, .buffering:
            playButton.image = symbol("pause.fill")
            playButton.bezelColor = nil
        case .finished:
            playButton.image = symbol("arrow.counterclockwise")
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

    @objc private func readTapped() { Log.info("Touch Bar: read"); onRead?() }
    @objc private func playTapped() { Log.info("Touch Bar: play/pause"); session?.togglePlay() }
    @objc private func backTapped() { Log.info("Touch Bar: back"); session?.skip(by: -Settings.shared.skipSeconds) }
    @objc private func forwardTapped() { Log.info("Touch Bar: forward"); session?.skip(by: Settings.shared.skipSeconds) }
    @objc private func windowTapped() { Log.info("Touch Bar: reading window"); onToggleWindow?() }

    @objc private func dismissTapped() {
        Log.info("Touch Bar: dismiss")
        onDismiss?()
    }
}
