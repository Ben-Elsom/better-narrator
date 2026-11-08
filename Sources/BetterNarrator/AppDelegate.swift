import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let engine = SpeechEngine()
    private let touchBar = TouchBarController()
    private let clipboard = ClipboardWatcher()
    private let selection = SelectionWatcher()

    /// What the Touch Bar's Read button will read.
    private enum Pending {
        case copied(CopiedText)
        /// Highlighted text; the app's own copy is fetched (with formatting) when Read is pressed.
        case selection(String?)
    }
    private var pending: Pending?
    private let nowPlaying = NowPlaying()
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var keyMonitor: Any?
    private var subs: Set<AnyCancellable> = []

    private var sessions: [ReadingSession] = []
    private var windows: [UUID: NSWindow] = [:]
    private weak var activeSession: ReadingSession?
    private var homeWindow: NSWindow?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ note: Notification) {
        Log.reset()
        Log.info("Better Narrator starting")
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()
        buildStatusItem()

        engine.onSegment = { [weak self] job, seg in self?.session(forJob: job)?.receive(seg) }
        engine.onJobDone = { [weak self] job in self?.session(forJob: job)?.generationFinished() }
        engine.$status.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshStatusMenu() }.store(in: &subs)
        Settings.shared.$enabled.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] on in self?.applyEnabled(on) }.store(in: &subs)
        if Settings.shared.enabled { engine.start() } else { engine.markOff() }

        touchBar.onRead = { [weak self] in self?.readOffer() }
        touchBar.onDismiss = { [weak self] in self?.dismissActive() }
        touchBar.onToggleWindow = { [weak self] in self?.toggleReadingWindow() }

        clipboard.onCopy = { [weak self] copied in
            Log.info("copy seen (\(copied.text.count) chars\(copied.html != nil ? ", formatted" : "")), offering Read")
            self?.offer(.copied(copied), preview: ReadingDocument(markdown: copied.text).plainText)
        }
        clipboard.start()

        selection.onSelection = { [weak self] text in
            Log.info("highlight seen (\(text.map { "\($0.count) chars" } ?? "app doesn't share it")), offering Read")
            self?.offer(.selection(text), preview: text ?? "Highlighted text")
        }
        selection.onSelectionCleared = { [weak self] in
            guard let self, case .selection? = self.pending else { return }
            self.touchBar.withdrawOffer()
        }
        selection.start()
        applyEnabled(Settings.shared.enabled, launching: true)
        touchBar.onOfferExpired = { [weak self] in self?.pending = nil }

        nowPlaying.session = { [weak self] in self?.activeSession }

        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey), id: 1) { [weak self] in
            self?.readSelection()
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handleKey(e) == true ? nil : e
        }

        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        showHome()
    }

    /// Shows the home window (how to use it, voice and speed, Read Clipboard).
    @objc func showHome() {
        if homeWindow == nil {
            let host = NSHostingView(rootView: HomeView(engine: engine,
                                                     readClipboard: { [weak self] in self?.readClipboard() },
                                                     readAgain: { [weak self] in self?.openReading($0.text) }))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.contentView = host
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.tabbingMode = .disallowed
            w.delegate = self
            w.center()
            homeWindow = w
        }
        NSApp.setActivationPolicy(.regular)
        homeWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ note: Notification) {
        touchBar.shutdown()
        sessions.forEach { $0.close() }
        engine.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if sessions.isEmpty { showHome() } else { showActiveWindow() }
        return true
    }

    // MARK: - Readings

    private func session(forJob job: String) -> ReadingSession? {
        sessions.first { $0.jobID == job }
    }

    private func offer(_ p: Pending, preview: String) {
        pending = p
        touchBar.offer(preview: preview)
    }

    private func readOffer() {
        guard let p = pending else { return }
        touchBar.setProcessing(true)  // set first, so the button never leaves the bar
        touchBar.withdrawOffer()
        switch p {
        case .copied(let copied):
            openReading(copied.forReading)
        case .selection(let known):
            // Copy the highlight so its headings, lists and paragraphs come with it.
            clipboard.copySelection { [weak self] copied in
                if let copied { self?.openReading(copied.forReading) }
                else if let known { self?.openReading(known) }
                else { self?.touchBar.setProcessing(false); NSSound.beep() }
            }
        }
    }

    @objc func readClipboard() {
        guard Settings.shared.enabled else { NSSound.beep(); return }
        guard let copied = ClipboardWatcher.read() else { NSSound.beep(); return }
        openReading(copied.forReading)
    }

    // MARK: - On / Off

    @objc func toggleEnabled() { Settings.shared.enabled.toggle() }

    /// Off stops the voice engine and stops watching copies and highlights, so
    /// Better Narrator uses no CPU and little memory until it's turned on again.
    private func applyEnabled(_ on: Bool, launching: Bool = false) {
        clipboard.isEnabled = on
        selection.isEnabled = on
        if on {
            if !launching && engine.status == .off { engine.start() }
        } else {
            touchBar.withdrawOffer()
            for w in Array(windows.values) { w.close() }
            touchBar.show(session: nil)
            engine.stop()
        }
        statusItem?.button?.appearsDisabled = !on
        if !launching { Log.info("Better Narrator turned \(on ? "on" : "off")") }
    }

    @objc func readSelection() {
        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            Log.info("asked for Accessibility permission")
            return
        }
        guard Settings.shared.enabled else { NSSound.beep(); return }
        clipboard.copySelection { [weak self] copied in
            guard let copied else { NSSound.beep(); return }
            self?.openReading(copied.forReading)
        }
    }

    func openReading(_ text: String) {
        let doc = ReadingDocument(markdown: text)
        guard !doc.segments.isEmpty else { touchBar.setProcessing(false); NSSound.beep(); return }
        touchBar.setProcessing(true)
        History.shared.add(title: doc.title, text: text)
        let session = ReadingSession(document: doc, voice: Settings.shared.voice)
        session.onStateChange = { [weak self, weak session] in
            guard let self, let session else { return }
            if session.isPlaying { self.pauseOthers(than: session) }
            if session === self.activeSession { self.nowPlaying.update() }
        }
        session.startWhenReady = true  // pressing Read means "read it": no extra Start press
        sessions.append(session)
        engine.synthesize(job: session.jobID, voice: session.voice, segments: doc.segments)
        Log.info("reading opened: \(doc.segments.count) segments, \(doc.plainText.count) chars")
        let show = Settings.shared.showWindowOnRead
        if show { homeWindow?.orderOut(nil) }
        openWindow(for: session, show: show)
        setActive(session)
        touchBar.setWindowShown(show)
    }

    private func pauseOthers(than session: ReadingSession) {
        for s in sessions where s !== session && s.isPlaying { s.pause() }
    }

    private func setActive(_ session: ReadingSession?) {
        activeSession = session
        touchBar.show(session: session)
        if let session { engine.focus(job: session.jobID) }
        nowPlaying.update()
    }

    /// Creates the reading window. It's only put on screen when `show` is true;
    /// otherwise it waits for "Show Reading Window" in the menu bar.
    private func openWindow(for session: ReadingSession, show: Bool) {
        let host = NSHostingView(rootView: ReaderView(session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.title = session.document.title
        window.subtitle = "Better Narrator"
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "BetterNarratorReading"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
        window.delegate = self
        window.setFrameAutosaveName("BetterNarratorReader")
        if windows.isEmpty { window.center() }
        windows[session.id] = window
        guard show else { return }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showActiveWindow() {
        guard let s = activeSession ?? sessions.last, let w = windows[s.id] else { return }
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        touchBar.setWindowShown(true)
    }

    private var readingWindowVisible: Bool {
        guard let s = activeSession ?? sessions.last, let w = windows[s.id] else { return false }
        return w.isVisible
    }

    /// Shows the text with the blue highlight, or puts it away. Reading carries on either way.
    @objc func toggleReadingWindow() {
        guard let s = activeSession ?? sessions.last, let w = windows[s.id] else { return }
        if w.isVisible { hideReadingWindow(w) } else { showActiveWindow() }
    }

    private func hideReadingWindow(_ w: NSWindow) {
        w.orderOut(nil)
        touchBar.setWindowShown(false)
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey }) {
            NSApp.hide(nil)  // gives the keyboard back to the app you were in
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }

    /// The window's close button puts the page away. Dismiss is what ends a reading.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard windows.values.contains(where: { $0 === sender }) else { return true }
        hideReadingWindow(sender)
        return false
    }

    @objc func dismissActive() {
        guard let s = activeSession, let w = windows[s.id] else { return }
        w.close() // windowWillClose tidies up
    }

    func windowDidBecomeKey(_ note: Notification) {
        guard let w = note.object as? NSWindow, let id = windows.first(where: { $0.value === w })?.key,
              let s = sessions.first(where: { $0.id == id }), s !== activeSession else { return }
        setActive(s)
    }

    func windowWillClose(_ note: Notification) {
        if let w = note.object as? NSWindow, w === homeWindow {
            if sessions.isEmpty { DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) } }
            return
        }
        guard let w = note.object as? NSWindow, let id = windows.first(where: { $0.value === w })?.key,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let s = sessions.remove(at: idx)
        windows[id] = nil
        engine.cancel(job: s.jobID)
        s.close()
        Log.info("reading closed")
        if activeSession === s || activeSession == nil {
            setActive(sessions.last)
            touchBar.setWindowShown(readingWindowVisible)
        }
        if sessions.isEmpty {
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }

    // MARK: - Keys in the reading window

    private func handleKey(_ e: NSEvent) -> Bool {
        guard let s = activeSession, let key = NSApp.keyWindow, windows.values.contains(where: { $0 === key }) else { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { return false }
        switch Int(e.keyCode) {
        case kVK_Space: Log.info("keyboard: space"); s.togglePlay(); return true
        case kVK_LeftArrow: s.skip(by: -Settings.shared.skipSeconds); return true
        case kVK_RightArrow: s.skip(by: Settings.shared.skipSeconds); return true
        default: return false
        }
    }

    // MARK: - URL commands (betternarrator://…), used for testing and automation

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let str = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URLComponents(string: str), let host = url.host else { return }
        let q = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let s = activeSession
        Log.info("url command: \(host) \(q)")
        switch host {
        case "read-clipboard": readClipboard()
        case "offer-clipboard":
            if let c = ClipboardWatcher.read() { offer(.copied(c), preview: c.text) }
        case "read-offer": readOffer()
        case "toggle": s?.togglePlay()
        case "play": s?.play()
        case "pause": s?.pause()
        case "skip": s?.skip(by: Double(q["by"] ?? "15") ?? 15)
        case "seek": s?.seek(to: Double(q["t"] ?? "0") ?? 0)
        case "speed": if let v = Double(q["x"] ?? "") { Settings.shared.speed = v }
        case "unfollow": s?.following = false
        case "jump-live": s?.following = true
        case "dismiss": dismissActive()
        case "touchbar": touchBar.present()
        case "touchbar-volume": touchBar.showVolumeSlider()
        case "toggle-window": toggleReadingWindow()
        case "history": if let i = Int(q["i"] ?? "0"), i < History.shared.items.count { openReading(History.shared.items[i].text) }
        case "power": Settings.shared.enabled = (q["on"] ?? "1") != "0"
        case "read-selection": readSelection()
        case "read-offer-selection": offer(.selection(nil), preview: "Highlighted text"); readOffer()
        case "snapshot":
            // Saves a picture of the reading window (used for testing; needs no screen permission).
            if let v = (s.flatMap { windows[$0.id] } ?? homeWindow)?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BetterNarrator_snapshot.png")
                try? rep.representation(using: .png, properties: [:])?.write(to: out)
                Log.info("snapshot saved")
            }
        case "state":
            if let s {
                Log.info("state=\(s.state) pos=\(String(format: "%.2f", s.position)) gen=\(String(format: "%.2f", s.generated)) total~\(String(format: "%.1f", s.estimatedTotal)) ready=\(String(format: "%.2f", s.readiness)) done=\(s.generationComplete) word=\(s.currentWord.map { (s.document.plainText as NSString).substring(with: $0.range) } ?? "-") following=\(s.following) sessions=\(sessions.count)")
            } else {
                Log.info("state: no reading open, engine=\(engine.status)")
            }
        default: break
        }
    }

    // MARK: - Menus

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"), let img = NSImage(contentsOf: url) {
            img.isTemplate = true
            img.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = img
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Better Narrator")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        menu.removeAllItems()
        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let power = item(Settings.shared.enabled ? "Turn Off Better Narrator" : "Turn On Better Narrator",
                         #selector(toggleEnabled), image: "power")
        menu.addItem(power)
        menu.addItem(.separator())
        menu.addItem(item("Read Clipboard Aloud", #selector(readClipboard), image: "doc.on.clipboard"))
        let sel = item("Read Selected Text", #selector(readSelection), image: "text.cursor")
        sel.keyEquivalent = "r"
        sel.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(sel)
        menu.addItem(.separator())
        if sessions.isEmpty {
            menu.addItem(item("Open Better Narrator", #selector(showHome), image: "macwindow"))
        } else {
            menu.addItem(item(readingWindowVisible ? "Hide Reading Window" : "Show Reading Window",
                              #selector(toggleReadingWindow), image: "doc.plaintext"))
            menu.addItem(item("Stop Reading", #selector(dismissActive), image: "xmark"))
        }
        let showItem = item("Open Window When Reading Starts", #selector(toggleShowWindow))
        showItem.state = Settings.shared.showWindowOnRead ? .on : .off
        menu.addItem(showItem)
        let tb = item("Show Touch Bar Controls", #selector(showTouchBar), image: "rectangle.and.hand.point.up.left")
        tb.isEnabled = !sessions.isEmpty
        menu.addItem(tb)
        menu.addItem(.separator())

        let voiceItem = NSMenuItem(title: "Voice: \(Settings.shared.voiceName)", action: nil, keyEquivalent: "")
        voiceItem.image = NSImage(systemSymbolName: "person.wave.2", accessibilityDescription: nil)
        let voices = NSMenu()
        for accent in ["American", "British"] {
            voices.addItem(NSMenuItem.sectionHeader(title: accent))
            for v in Settings.voices where v.accent == accent {
                let mi = NSMenuItem(title: v.name, action: #selector(pickVoice(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = v.id
                mi.state = v.id == Settings.shared.voice ? .on : .off
                voices.addItem(mi)
            }
        }
        voiceItem.submenu = voices
        menu.addItem(voiceItem)

        let speedItem = NSMenuItem(title: "Speed: \(formatSpeed(Settings.shared.speed))", action: nil, keyEquivalent: "")
        speedItem.image = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil)
        let speeds = NSMenu()
        for sp in Settings.speeds {
            let mi = NSMenuItem(title: formatSpeed(sp), action: #selector(pickSpeed(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = sp
            mi.state = sp == Settings.shared.speed ? .on : .off
            speeds.addItem(mi)
        }
        speedItem.submenu = speeds
        menu.addItem(speedItem)
        menu.addItem(.separator())
        menu.addItem(item("Quit Better Narrator", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private var statusLine: String {
        switch engine.status {
        case .starting: return "Starting voice engine…"
        case .ready:
            if let s = activeSession { return sessions.count > 1 ? "\(sessions.count) readings open" : "Reading: \(s.document.title)" }
            return "Ready: copy text, then tap Read"
        case .failed(let m): return m
        case .off: return "Off: not listening, using no power"
        }
    }

    private func refreshStatusMenu() {
        statusItem?.button?.appearsDisabled = engine.status != .ready
    }

    private func item(_ title: String, _ action: Selector, key: String = "", image: String? = nil, target: AnyObject? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = target ?? self
        if let image { mi.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
        return mi
    }

    @objc private func pickVoice(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { Settings.shared.voice = id }
    }

    @objc private func pickSpeed(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? Double { Settings.shared.speed = s }
    }

    @objc private func showTouchBar() { touchBar.present() }
    @objc private func toggleShowWindow() { Settings.shared.showWindowOnRead.toggle() }

    @objc private func togglePlayMenu() { Log.info("menu: play/pause"); activeSession?.togglePlay() }
    @objc private func backMenu() { activeSession?.skip(by: -Settings.shared.skipSeconds) }
    @objc private func forwardMenu() { activeSession?.skip(by: Settings.shared.skipSeconds) }
    @objc private func jumpLiveMenu() { activeSession?.following = true }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Better Narrator", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Better Narrator", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Better Narrator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let playItem = NSMenuItem()
        let play = NSMenu(title: "Playback")
        play.addItem(item("Play / Pause", #selector(togglePlayMenu), key: "p"))
        play.addItem(item("Back 15 Seconds", #selector(backMenu), key: "["))
        play.addItem(item("Forward 15 Seconds", #selector(forwardMenu), key: "]"))
        play.addItem(.separator())
        play.addItem(item("Jump to Live", #selector(jumpLiveMenu), key: "l"))
        play.addItem(.separator())
        play.addItem(item("Read Clipboard Aloud", #selector(readClipboard), key: "v", target: nil).then { $0.keyEquivalentModifierMask = [.command, .shift]; $0.target = self })
        playItem.submenu = play
        main.addItem(playItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}

extension NSMenuItem {
    func then(_ f: (NSMenuItem) -> Void) -> NSMenuItem { f(self); return self }
}
