import AppKit
import Combine

/// Puts Better Narrator's buttons on the Touch Bar, on the right-hand side,
/// even while another app is in front.
final class TouchBarController: NSObject, NSTouchBarDelegate {
    private enum ID {
        static let tray = NSTouchBarItem.Identifier("app.betternarrator.tray")
        static let copied = NSTouchBarItem.Identifier("app.betternarrator.copied")
        static let read = NSTouchBarItem.Identifier("app.betternarrator.read")
        static let dismiss = NSTouchBarItem.Identifier("app.betternarrator.dismiss")
        static let back = NSTouchBarItem.Identifier("app.betternarrator.back")
        static let play = NSTouchBarItem.Identifier("app.betternarrator.play")
        static let forward = NSTouchBarItem.Identifier("app.betternarrator.forward")
        static let gap = NSTouchBarItem.Identifier.fixedSpaceSmall
        static let sideGap = NSTouchBarItem.Identifier("app.betternarrator.sidegap")
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
    private weak var sliderItem: NSSliderTouchBarItem?

    var onRead: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onToggleWindow: (() -> Void)?

    private let bar = NSTouchBar()
    private var presented = false
    private var processing = false
    private var processingTimeout: Timer?
    /// The reading that Read just opened. Other open readings don't end the processing.
    private weak var processingSession: ReadingSession?
    private var catView: NSView?
    /// A live copy of Touch Bar Pet's cat, because macOS shows only one app's bar at a time.
    private let cat = CatMirrorView()
    private var settingsSub: AnyCancellable?

    private weak var session: ReadingSession?
    private var sessionSubs: Set<AnyCancellable> = []
    private var audioTimer: Timer?
    private var lastButtonStyle = ""
    private var sliderShowsMuted: Bool?
    private var lastSliderMove = Date.distantPast
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
        // With a reading open, the wheel takes up all the free space, so the buttons to its
        // right always end at the bar's right edge, whatever fits on the left.
        w.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        w.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return w
    }()
    private lazy var wheelFixedWidth = wheel.widthAnchor.constraint(equalToConstant: 190)
    private lazy var muteButton = symbolButton("speaker.slash.fill", #selector(muteTapped), width: 44)
    private lazy var volumeButton = symbolButton("speaker.wave.2.fill", #selector(volumeTapped), width: 44)
    private lazy var windowButton = symbolButton("doc.plaintext", #selector(windowTapped), width: 52)
    private lazy var copiedLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.textColor = .secondaryLabelColor
        l.font = .systemFont(ofSize: 13)
        l.lineBreakMode = .byTruncatingTail
        l.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        return l
    }()
    private lazy var dismissButton = symbolButton("xmark", #selector(dismissTapped), width: 52)
    private lazy var backButton = symbolButton("gobackward.15", #selector(backTapped), width: 58)
    private lazy var forwardButton = symbolButton("goforward.15", #selector(forwardTapped), width: 58)
    private lazy var playButton: NSButton = {
        let b = NSButton(title: "", target: self, action: #selector(playTapped))
        b.imagePosition = .imageOnly
        b.widthAnchor.constraint(equalToConstant: 74).isActive = true
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
            return [ID.previous, ID.media, ID.next, ID.mute, ID.volume, ID.brightness]
        }
    }

    // MARK: - What to show

    func show(session: ReadingSession?) {
        self.session = session
        if processing { processingSession = session }
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

    /// Read was pressed: Read goes away and ✕ is disabled until talking starts.
    func setProcessing(_ on: Bool) {
        guard processing != on else { return }
        processing = on
        processingSession = on ? processingSession : nil
        // If the voice engine never gets going, don't leave ✕ disabled for good.
        processingTimeout?.invalidate()
        if on {
            processingTimeout = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
                Log.info("still processing after 45 s, giving ✕ back")
                self?.setProcessing(false)
            }
        }
        rebuild()
    }

    /// The live cat from Touch Bar Pet, shown at the far left. Nil when the pet isn't running.
    func setCat(_ view: NSView?) {
        catView = view
        bar.defaultItemIdentifiers = []
        rebuild()
    }

    /// Shows whether the reading window is open and in front (lit) or put away or behind
    /// another window (plain), so one press always does the obvious thing.
    func setWindowShown(_ shown: Bool) {
        windowButton.image = NSImage(systemSymbolName: shown ? "doc.plaintext.fill" : "doc.plaintext", accessibilityDescription: nil)
        windowButton.bezelColor = shown ? .systemBlue : nil
    }

    private func rebuild() {
        // Read sits at the far right, and only when there's something to press it for.
        // Once pressed it goes: the play button shows the progress.
        let showRead = offerText != nil && !processing
        // While a highlight is being copied there's no reading yet, but the controls show anyway.
        let showControls = session != nil || processing
        // Read's room comes out of the slower (left) end of the wheel, so the buttons keep
        // their size and place and the faster speeds stay where they were.
        wheel.trimsLeft = showRead && showControls && expanded == nil
        // An open slider takes the free space itself, so it needs no flexible space beside it.
        var ids: [NSTouchBarItem.Identifier] = (catView != nil ? [ID.cat] : []) + systemStrip
        if expanded == nil && !showControls { ids.append(.flexibleSpace) }
        // An open slider gets the free space instead of the wheel.
        wheelFixedWidth.isActive = expanded != nil
        if showControls {
            // The wheel is on the right, where a right hand reaches it most easily.
            // The larger gap separates the computer's controls from Better Narrator's.
            ids += [ID.sideGap, ID.dismiss, ID.window, ID.back, ID.play, ID.forward, ID.wheel]
            if showRead { ids += [ID.gap, ID.read] }
        } else if offerText != nil {
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
        dismissButton.isEnabled = !processing
        readButton.bezelColor = .systemBlue
    }

    func present() {
        guard bar.defaultItemIdentifiers.count > 1 else { return }
        cat.isPaused = false
        startWatchingAudio()
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
        audioTimer?.invalidate()
        audioTimer = nil
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
        case ID.sideGap:
            // A real view, because this bar doesn't draw the built-in fixed spaces.
            let spacer = NSView()
            spacer.widthAnchor.constraint(equalToConstant: 14).isActive = true
            item.view = spacer
        case ID.wheel: item.view = wheel
        case ID.window: item.view = windowButton
        case ID.cat:
            guard let catView else { return nil }
            item.view = catView
            item.visibilityPriority = .normal
        case ID.copied: item.view = copiedLabel
        case ID.dismiss: item.view = dismissButton
        case ID.back: item.view = backButton
        case ID.play: item.view = playButton
        case ID.forward: item.view = forwardButton
        default: return nil
        }
        return item
    }

    // MARK: - Control Strip copies

    // The bar drops every item of the lowest level at once. ⏪ and ⏩ share a level so
    // one never goes without the other; mute has its own so it goes last.
    private static let dropFirst = NSTouchBarItem.Priority(rawValue: -1000)
    private static let dropLast = NSTouchBarItem.Priority(rawValue: -500)

    private func makeSystemItem(_ identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        switch identifier {
        case ID.previous:
            item.view = symbolButton("backward.fill", #selector(previousTapped), width: 44)
            item.visibilityPriority = Self.dropFirst
        case ID.media: item.view = symbolButton("playpause.fill", #selector(mediaTapped), width: 44)
        case ID.next:
            item.view = symbolButton("forward.fill", #selector(nextTapped), width: 44)
            item.visibilityPriority = Self.dropFirst
        case ID.mute:
            item.view = muteButton
            item.visibilityPriority = Self.dropLast
        case ID.volume: item.view = volumeButton
        case ID.brightness: item.view = symbolButton("sun.max.fill", #selector(brightnessTapped), width: 44)
        case ID.close:
            // Not an xmark: that's the Dismiss button, which ends the reading.
            item.view = symbolButton("chevron.left", #selector(collapseSlider), width: 44)
            item.visibilityPriority = .high
        case ID.slider:
            let slider = NSSliderTouchBarItem(identifier: identifier)
            let isVolume = expanded == .volume
            slider.slider.minValue = 0
            slider.slider.maxValue = 1
            slider.slider.doubleValue = Double(isVolume ? SystemControls.volume : SystemControls.brightness)
            slider.minimumValueAccessory = NSSliderAccessory(image: NSImage(systemSymbolName: isVolume ? "speaker.fill" : "sun.min.fill", accessibilityDescription: nil)!)
            slider.maximumValueAccessory = NSSliderAccessory(image: NSImage(systemSymbolName: isVolume ? "speaker.wave.3.fill" : "sun.max.fill", accessibilityDescription: nil)!)
            // The bar drops any item that doesn't fit, so this must fit beside the reading
            // controls. It grows into whatever room is free.
            slider.slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
            slider.slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
            slider.target = self
            slider.action = #selector(sliderMoved(_:))
            slider.visibilityPriority = .high
            sliderItem = slider
            sliderShowsMuted = nil
            refreshAudioStyle()
            return slider
        default:
            return nil
        }
        return item
    }

    @objc private func previousTapped() { SystemControls.press(.previous) }
    @objc private func mediaTapped() { SystemControls.press(.play) }
    @objc private func nextTapped() { SystemControls.press(.next) }
    @objc private func muteTapped() {
        SystemControls.isMuted.toggle()
        Log.info("Touch Bar: mute, now \(SystemControls.isMuted ? "muted" : "on")")
        refreshAudioStyle()
    }
    @objc private func volumeTapped() { expand(.volume) }
    @objc private func brightnessTapped() { expand(.brightness) }

    func showVolumeSlider() { expand(.volume) }
    func showBrightnessSlider() { expand(.brightness) }

    /// For testing: presses ✕ as a finger would.
    func pressDismiss() { dismissButton.performClick(nil) }

    /// For testing: presses the mute button as a finger would.
    func pressMute() { muteButton.performClick(nil) }

    /// For testing: moves the open slider as a finger would.
    func moveSlider(to value: Double) {
        guard let sliderItem else { return Log.info("Touch Bar: no slider on the bar") }
        sliderItem.slider.doubleValue = value
        NSApp.sendAction(#selector(sliderMoved(_:)), to: self, from: sliderItem)
    }

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

    @objc private func sliderMoved(_ sender: Any?) {
        guard let v = sliderItem.map({ Float($0.slider.doubleValue) }) else { return }
        if expanded == .volume { SystemControls.volume = v } else { SystemControls.brightness = v }
        lastSliderMove = Date()
        refreshAudioStyle()
        scheduleCollapse()
    }

    // MARK: - Muted look

    /// Mute can also change from the keyboard or another app, so keep checking while the bar is up.
    private func startWatchingAudio() {
        refreshAudioStyle()
        guard audioTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshAudioStyle() }
        RunLoop.main.add(timer, forMode: .common)
        audioTimer = timer
    }

    private func refreshAudioStyle() {
        let muted = SystemControls.isMuted
        let volume = SystemControls.volume
        let symbol = muted ? "speaker.slash.fill"
            : volume < 0.01 ? "speaker.fill"
            : volume < 0.34 ? "speaker.wave.1.fill"
            : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        let style = "\(muted) \(symbol)"
        if style != lastButtonStyle {
            lastButtonStyle = style
            muteButton.bezelColor = muted ? .systemRed : nil
            volumeButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            volumeButton.contentTintColor = muted ? .secondaryLabelColor : nil
        }
        guard expanded == .volume, let sliderItem else { return }
        if sliderShowsMuted != muted {
            sliderShowsMuted = muted
            sliderItem.slider.trackFillColor = muted ? .systemGray : nil
            sliderItem.minimumValueAccessory = NSSliderAccessory(image: NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.fill", accessibilityDescription: nil)!)
        }
        // Don't fight a finger that's still moving the slider.
        if Date().timeIntervalSince(lastSliderMove) > 0.5 {
            sliderItem.slider.doubleValue = muted ? 0 : Double(volume)
        }
    }

    private func refreshControls() {
        windowButton.isEnabled = session != nil
        // Still copying the highlight: the new reading doesn't exist yet.
        if processing && processingSession == nil {
            playButton.isEnabled = false
            playButton.imagePosition = .noImage
            playButton.image = nil
            playButton.bezelColor = nil
            playButton.title = "0%"
            backButton.isEnabled = false
            forwardButton.isEnabled = false
            return
        }
        guard let s = session else { return }
        if processing && s === processingSession && s.state != .preparing && s.state != .ready {
            setProcessing(false)
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
