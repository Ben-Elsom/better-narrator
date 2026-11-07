import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MediaPlayer

// MARK: - Now Playing (⏯ key, menu bar Now Playing, Touch Bar media controls)

final class NowPlaying {
    var session: () -> ReadingSession? = { nil }

    init() {
        let c = MPRemoteCommandCenter.shared()
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Log.info("media key: toggle"); return self?.with { $0.togglePlay() } ?? .commandFailed }
        c.playCommand.addTarget { [weak self] _ in Log.info("media key: play"); return self?.with { $0.play() } ?? .commandFailed }
        c.pauseCommand.addTarget { [weak self] _ in Log.info("media key: pause"); return self?.with { $0.pause() } ?? .commandFailed }
        c.skipForwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { [weak self] _ in self?.with { $0.skip(by: Settings.shared.skipSeconds) } ?? .commandFailed }
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.with { $0.skip(by: -Settings.shared.skipSeconds) } ?? .commandFailed }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.with { $0.seek(to: e.positionTime) } ?? .noActionableNowPlayingItem
        }
        c.nextTrackCommand.isEnabled = false
        c.previousTrackCommand.isEnabled = false
    }

    private func with(_ f: (ReadingSession) -> Void) -> MPRemoteCommandHandlerStatus {
        guard let s = session() else { return .noActionableNowPlayingItem }
        f(s)
        update()
        return .success
    }

    func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let s = session() else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: s.document.title,
            MPMediaItemPropertyArtist: "Better Narrator · \(Settings.voices.first { $0.id == s.voice }?.name ?? "")",
            MPMediaItemPropertyPlaybackDuration: max(s.estimatedTotal, s.generated),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: s.position,
            MPNowPlayingInfoPropertyPlaybackRate: s.isPlaying ? Settings.shared.speed : 0,
        ]
        center.playbackState = s.isPlaying ? .playing : .paused
    }
}

// MARK: - Global shortcut (⌃⌥R reads the highlighted text)

final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var instances: [UInt32: HotKey] = [:]

    init(keyCode: UInt32, modifiers: UInt32, id: UInt32, action: @escaping () -> Void) {
        self.action = action
        HotKey.instances[id] = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { HotKey.instances[hk.id]?.action() }
            return noErr
        }, 1, &spec, nil, &handler)
        let hotKeyID = EventHotKeyID(signature: OSType(0x424E5252), id: id) // 'BNRR'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - Accessibility permission

final class Permissions: ObservableObject {
    static let shared = Permissions()
    @Published private(set) var accessibility = AXIsProcessTrusted()
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            let now = AXIsProcessTrusted()
            if now != self?.accessibility { self?.accessibility = now; Log.info("accessibility permission: \(now)") }
        }
    }

    /// Shows macOS's prompt, which offers to open the Accessibility settings.
    func request() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
}

// MARK: - Highlighted text

/// Notices when you highlight text in another app (by dragging, double- or
/// triple-clicking, or with the keyboard). Native apps say what's highlighted;
/// for apps that don't (Claude and other web-based apps), Read copies the
/// highlight when you press it.
final class SelectionWatcher {
    var isEnabled = true
    var onSelection: ((String?) -> Void)?
    var onSelectionCleared: (() -> Void)?

    private var monitors: [Any] = []
    private var downPoint: NSPoint = .zero
    private var dragged = false
    private var offered = false

    func start() {
        let m1 = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.downPoint = NSEvent.mouseLocation
            self?.dragged = false
        }
        let m2 = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            if hypot(p.x - self.downPoint.x, p.y - self.downPoint.y) > 6 { self.dragged = true }
        }
        let m3 = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] e in
            guard let self else { return }
            let selecting = self.dragged || e.clickCount >= 2
            let inTitleBar = self.isInTitleBar(self.downPoint)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self.check(expectSelection: selecting && !inTitleBar)
            }
        }
        let m4 = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp]) { [weak self] e in
            // Shift+arrows, or ⌘A
            let isSelectAll = e.modifierFlags.contains(.command) && e.charactersIgnoringModifiers == "a"
            if e.modifierFlags.contains(.shift) || isSelectAll {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self?.check(expectSelection: true) }
            }
        }
        monitors = [m1, m2, m3, m4].compactMap { $0 }
    }

    private func check(expectSelection: Bool) {
        guard isEnabled, AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let known = selectedText(in: app)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known, known.rangeOfCharacter(from: .letters) != nil {
            offered = true
            onSelection?(known)
        } else if known == nil && expectSelection {
            // The app doesn't say what's highlighted; offer Read and copy on press.
            offered = true
            onSelection?(nil)
        } else if offered {
            offered = false
            onSelectionCleared?()
        }
    }

    /// True when a drag started in the top strip of the front window (moving the window).
    private func isInTitleBar(_ p: NSPoint) -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let win = list.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }),
              let b = win[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let y = screenHeight - p.y  // flip to window-list coordinates
        let x = p.x
        let minX = b["X"] ?? 0, minY = b["Y"] ?? 0, w = b["Width"] ?? 0
        return x >= minX && x <= minX + w && y >= minY && y <= minY + 30
    }

    /// The highlighted text, if the app shares it. Doesn't ask web-based apps
    /// to turn on their extra accessibility data, which costs them CPU.
    private func selectedText(in app: NSRunningApplication) -> String? {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        var sel: CFTypeRef?
        guard AXUIElementCopyAttributeValue(f as! AXUIElement, kAXSelectedTextAttribute as CFString, &sel) == .success else { return nil }
        return sel as? String
    }
}

// MARK: - Clipboard

struct CopiedText {
    let text: String
    let html: String?

    /// The best version for reading: the formatted copy turned into Markdown
    /// when there is one, otherwise the plain text.
    var forReading: String {
        if let html, let md = HTMLImport.markdown(fromHTML: html), md.count >= text.count / 2 { return md }
        return text
    }
}

final class ClipboardWatcher {
    var isEnabled = true
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var ignoreUpTo: Int?
    var onCopy: ((CopiedText) -> Void)?

    private static let skipTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
    ]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.check() }
    }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        if let ignore = ignoreUpTo, pb.changeCount <= ignore { return }
        guard isEnabled else { return }
        let types = Set((pb.types ?? []).map(\.rawValue))
        if !types.isDisjoint(with: ClipboardWatcher.skipTypes) { return }  // passwords and the like
        guard let copied = ClipboardWatcher.read(pb) else { return }
        onCopy?(copied)
    }

    static func read(_ pb: NSPasteboard = .general) -> CopiedText? {
        guard let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.rangeOfCharacter(from: .letters) != nil else { return nil }
        return CopiedText(text: text, html: pb.string(forType: .html))
    }

    /// Presses ⌘C in the front app, returns what it copied, then puts the
    /// clipboard back the way it was.
    func copySelection(completion: @escaping (CopiedText?) -> Void) {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
        let before = pb.changeCount
        ignoreUpTo = before + 3
        Log.info("copying highlight from \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") (trusted: \(AXIsProcessTrusted()))")
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            tries += 1
            guard pb.changeCount != before || tries > 40 else { return }
            t.invalidate()
            let copied = pb.changeCount != before ? ClipboardWatcher.read(pb) : nil
            Log.info(copied.map { "copied highlight: \($0.text.count) chars\($0.html != nil ? ", formatted" : "")" } ?? "copy got nothing")
            if pb.changeCount != before {
                // Put back whatever was on the clipboard before.
                pb.clearContents()
                let items: [NSPasteboardItem] = saved.map { d in
                    let item = NSPasteboardItem()
                    for (t, data) in d { item.setData(data, forType: t) }
                    return item
                }
                if !items.isEmpty { pb.writeObjects(items) }
                self.ignoreUpTo = pb.changeCount
                self.lastChange = pb.changeCount
            }
            completion(copied)
        }
    }
}
