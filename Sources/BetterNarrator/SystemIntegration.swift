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
/// triple-clicking, or with the keyboard) and reports what's highlighted.
final class SelectionWatcher {
    var onSelection: ((String) -> Void)?
    var onSelectionUnknown: (() -> Void)?
    var onSelectionCleared: (() -> Void)?

    private var monitors: [Any] = []
    private var downPoint: NSPoint = .zero
    private var dragged = false
    private var lastText = ""
    private var electronEnabled: Set<pid_t> = []

    func start() {
        let m1 = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] e in
            self?.downPoint = NSEvent.mouseLocation
            self?.dragged = false
            _ = e
        }
        let m2 = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            if hypot(p.x - self.downPoint.x, p.y - self.downPoint.y) > 6 { self.dragged = true }
        }
        let m3 = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] e in
            guard let self else { return }
            let selecting = self.dragged || e.clickCount >= 2
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.check(expectSelection: selecting) }
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
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        guard let raw = selectedText(in: app) else {
            // This app doesn't say what's highlighted. After a drag or double-click,
            // offer Read anyway; pressing it copies the highlight first.
            if expectSelection && mouseIsOverText(app) { lastText = "?"; onSelectionUnknown?() }
            return
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.rangeOfCharacter(from: .letters) != nil {
            guard text != lastText || expectSelection else { return }
            lastText = text
            onSelection?(text)
        } else if !lastText.isEmpty {
            lastText = ""
            onSelectionCleared?()
        }
    }

    /// True when the pointer is over text (not, say, a window's title bar being dragged).
    private func mouseIsOverText(_ app: NSRunningApplication) -> Bool {
        let p = NSEvent.mouseLocation
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        var element: AXUIElement?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(screenHeight - p.y), &element) == .success,
              let el = element else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXWebArea", "AXHeading", "AXLink", "AXListItem", "AXParagraph"]
        return textRoles.contains(role as? String ?? "")
    }

    private func selectedText(in app: NSRunningApplication) -> String? {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        // Electron and Chrome-based apps (like Claude) only share their page
        // text with accessibility tools once asked.
        if !electronEnabled.contains(app.processIdentifier) {
            AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            electronEnabled.insert(app.processIdentifier)
        }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        var sel: CFTypeRef?
        guard AXUIElementCopyAttributeValue(f as! AXUIElement, kAXSelectedTextAttribute as CFString, &sel) == .success else { return nil }
        return sel as? String
    }
}

// MARK: - Clipboard

final class ClipboardWatcher {
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    var ignoreUntilChange: Int?
    var onCopy: ((String) -> Void)?

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
        if let ignore = ignoreUntilChange, pb.changeCount <= ignore { return }
        let types = Set((pb.types ?? []).map(\.rawValue))
        if !types.isDisjoint(with: ClipboardWatcher.skipTypes) { return }  // passwords and the like
        guard let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.rangeOfCharacter(from: .letters) != nil else { return }
        onCopy?(text)
    }

    /// Presses ⌘C in the front app and returns what it copied.
    func copySelection(completion: @escaping (String?) -> Void) {
        let before = NSPasteboard.general.changeCount
        ignoreUntilChange = before + 1
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            tries += 1
            let pb = NSPasteboard.general
            if pb.changeCount != before {
                t.invalidate()
                self.lastChange = pb.changeCount
                completion(pb.string(forType: .string))
            } else if tries > 20 {
                t.invalidate()
                completion(nil)
            }
        }
    }
}
