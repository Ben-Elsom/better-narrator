// CatMirrorView: a small copy of the Touch Bar Pet for another app's Touch Bar.
//
// Only one system-modal bar can be visible at a time, so an app that shows its
// own full-width bar can host this view to keep the cat on screen. It listens to
// the pet's state broadcast, so the pet does the thinking and this only draws.
//
//     let cat = CatMirrorView()
//     cat.onAvailabilityChange = { available in /* add or remove the item */ }
//     item.view = cat          // an NSCustomTouchBarItem
//
// It is 44pt wide, growing to at most 230pt while a note shows. Tapping it opens
// the Touch Bar Pet window. It redraws at most 10 times a second, only while it has a window,
// and draws nothing if the pet or its sprite is missing.
//
// Self-contained on purpose: copy this one file into the host app. Keep the names
// below in sync with Touch_Bar_Pet/Sources/main.swift.

import AppKit

final class CatMirrorView: NSView {
    private static let bundleID = "com.benelsom.touchbarpet"
    private static let stateNote = Notification.Name("com.benelsom.touchbarpet.state")
    private static let stateRequestNote = Notification.Name("com.benelsom.touchbarpet.stateRequest")
    private static let sayNote = Notification.Name("com.benelsom.touchbarpet.say")

    private static let idleWidth: CGFloat = 44
    private static let maxWidth: CGFloat = 230
    private static let scale: CGFloat = 2     // points per sprite pixel
    private static let frameSize = 32
    private static let artLeft: CGFloat = 7   // the cat starts at this column of each frame

    /// True while the Touch Bar Pet app is running.
    static var petIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Fires on the main thread when the pet starts or stops.
    var onAvailabilityChange: ((Bool) -> Void)?

    /// Set true while the host's bar is hidden to stop all animation work.
    var isPaused = false {
        didSet { updateTimer() }
    }

    private struct Anim: Equatable {
        let row: Int, count: Int, fps: Double
    }

    private enum Anims {
        static let sit = Anim(row: 0, count: 4, fps: 5)
        static let twitch = Anim(row: 1, count: 4, fps: 6)
        static let clean = Anim(row: 2, count: 4, fps: 6)
        static let walk = Anim(row: 4, count: 8, fps: 10)
        static let sleep = Anim(row: 6, count: 4, fps: 2.5)
        static let paw = Anim(row: 7, count: 6, fps: 8)
        static let jump = Anim(row: 8, count: 7, fps: 10)
        static let scared = Anim(row: 9, count: 8, fps: 10)
        static let contented = Anim(row: 10, count: 4, fps: 5)
    }

    private var frames: [[CGImage]] = []
    private var theme = ""
    private var mood = "gone"
    private var note: String?
    private var available = false

    private var anim = Anims.sit
    private var frameIndex = 0
    private var frameTime = 0.0
    private var loopsLeft = 3
    private var clock = 0.0
    private var timer: Timer?
    private var lastTick = Date()

    private let noteFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: 12.5) { return f }
        return base
    }()

    // MARK: Setup

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.idleWidth, height: 30))
        allowedTouchTypes = [.direct]
        if #available(macOS 14.0, *) { clipsToBounds = true }
        setContentHuggingPriority(.required, for: .horizontal)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(stateChanged(_:)), name: Self.stateNote, object: nil,
            suspensionBehavior: .deliverImmediately)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(appsChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appsChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        available = Self.petIsRunning
        requestState()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        timer?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func requestState() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.stateRequestNote, object: nil, userInfo: nil, deliverImmediately: true)
    }

    // MARK: Listening to the pet

    @objc private func appsChanged(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard app?.bundleIdentifier == Self.bundleID else { return }
        if note.name == NSWorkspace.didTerminateApplicationNotification {
            apply(mood: "gone", note: nil, theme: theme)
            setAvailable(false)
        } else {
            setAvailable(true)
            // Give it a moment to start listening.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.requestState() }
        }
    }

    @objc private func stateChanged(_ n: Notification) {
        let info = n.userInfo as? [String: Any] ?? [:]
        let newMood = info["mood"] as? String ?? "gone"
        apply(mood: newMood, note: info["note"] as? String,
              theme: info["theme"] as? String ?? theme)
        setAvailable(newMood != "gone")
    }

    private func setAvailable(_ value: Bool) {
        guard value != available else { return }
        available = value
        onAvailabilityChange?(value)
    }

    private func apply(mood newMood: String, note newNote: String?, theme newTheme: String) {
        if newTheme != theme || frames.isEmpty { loadFrames(theme: newTheme) }
        let moodChanged = newMood != mood
        let noteChanged = newNote != note
        mood = newMood
        note = newNote
        if moodChanged { chooseAnim() }
        if noteChanged { invalidateIntrinsicContentSize() }
        needsDisplay = true
    }

    private func chooseAnim() {
        let next: (Anim, Int)
        switch mood {
        case "working": next = (Anims.walk, 4)
        case "needs": next = (Anims.paw, 3)
        case "inactive": next = (Anims.sleep, 10)
        case "contented": next = (Anims.contented, 10)
        case "done": next = (Anims.jump, 1)
        case "alert": next = (Anims.scared, 2)
        default:
            let roll = Int.random(in: 0..<10)
            next = roll < 6 ? (Anims.sit, 3) : roll < 8 ? (Anims.twitch, 2) : (Anims.clean, 2)
        }
        anim = next.0
        loopsLeft = next.1
        frameIndex = 0
        frameTime = 0
    }

    // MARK: Animation

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    private func updateTimer() {
        let shouldRun = window != nil && !isPaused
        if shouldRun && timer == nil {
            lastTick = Date()
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 0.03
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !shouldRun {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        guard available, !frames.isEmpty else { return }
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 0.3)
        lastTick = now
        clock += dt

        var redraw = false
        frameTime += dt
        let perFrame = 1 / anim.fps
        while frameTime >= perFrame {
            frameTime -= perFrame
            frameIndex += 1
            redraw = true
            if frameIndex >= anim.count {
                frameIndex = 0
                loopsLeft -= 1
                if loopsLeft <= 0 { chooseAnim() }
            }
        }

        if anim == Anims.sleep { redraw = true }
        if redraw { needsDisplay = true }
    }

    // MARK: Size

    private var shownNote: String? {
        guard mood != "gone", let note, !note.isEmpty else { return nil }
        let room = Self.maxWidth - Self.idleWidth - 16
        return Self.fit(note, room: room) { self.text($0).size().width }
    }

    /// Shortens a note to fit, keeping "needs you" whole: that part is the message.
    /// Keep in sync with BarView.fit in Sources/main.swift.
    private static func fit(_ note: String, room: CGFloat, width: (String) -> CGFloat) -> String {
        if width(note) <= room { return note }
        var head = note
        var tail = ""
        if let r = note.range(of: " needs ", options: .backwards), r.lowerBound != note.startIndex {
            head = String(note[..<r.lowerBound])
            tail = String(note[r.lowerBound...])
        }
        while !head.isEmpty && width(head + "…" + tail) > room { head.removeLast() }
        return head.trimmingCharacters(in: .whitespaces) + "…" + tail
    }

    private func text(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: noteFont, .foregroundColor: NSColor(white: 0.08, alpha: 1)])
    }

    override var intrinsicContentSize: NSSize {
        guard let shown = shownNote else { return NSSize(width: Self.idleWidth, height: 30) }
        return NSSize(width: min(Self.maxWidth, Self.idleWidth + ceil(text(shown).size().width) + 16), height: 30)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard available, mood != "gone", let ctx = NSGraphicsContext.current?.cgContext,
              anim.row < frames.count, frameIndex < frames[anim.row].count else { return }

        let size = CGFloat(Self.frameSize) * Self.scale
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.draw(frames[anim.row][frameIndex],
                 in: CGRect(x: 4 - Self.artLeft * Self.scale, y: 0, width: size, height: size))
        ctx.restoreGState()

        if anim == Anims.sleep { drawZs() }
        if let shown = shownNote { drawNote(shown) }
    }

    private func drawZs() {
        for i in 0..<2 {
            let phase = (clock * 0.45 + Double(i) / 2).truncatingRemainder(dividingBy: 1)
            let s = NSAttributedString(string: "z", attributes: [
                .font: NSFont.systemFont(ofSize: 6 + phase * 3, weight: .heavy),
                .foregroundColor: NSColor(white: 0.85, alpha: sin(phase * .pi) * 0.85),
            ])
            s.draw(at: NSPoint(x: 30 + phase * 5, y: 10 + phase * 12))
        }
    }

    private func drawNote(_ shown: String) {
        let s = text(shown)
        let x = Self.idleWidth - 2
        let h: CGFloat = 22
        let y = (bounds.height - h) / 2
        let w = min(ceil(s.size().width) + 16, bounds.width - x)
        guard w > 16 else { return } // the host hasn't given us the room yet
        let color: NSColor
        switch mood {
        case "alert": color = NSColor(srgbRed: 1.00, green: 0.78, blue: 0.78, alpha: 1)
        case "done": color = NSColor(srgbRed: 0.80, green: 0.96, blue: 0.84, alpha: 1)
        case "needs": color = NSColor(srgbRed: 1.00, green: 0.88, blue: 0.55, alpha: 1)
        default: color = NSColor(white: 0.94, alpha: 1)
        }
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
        s.draw(at: NSPoint(x: x + 8, y: y + (h - s.size().height) / 2))
    }

    // MARK: Touch

    override func touchesEnded(with event: NSEvent) {
        post(["command": "tap"])
    }

    private func post(_ info: [String: String]) {
        DistributedNotificationCenter.default().postNotificationName(
            Self.sayNote, object: nil, userInfo: info, deliverImmediately: true)
    }

    // MARK: Sprite

    private static func spriteURL() -> URL? {
        var apps: [URL] = []
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { apps.append(u) }
        apps.append(URL(fileURLWithPath: NSHomeDirectory() + "/Applications/Touch_Bar_Pet.app"))
        for app in apps {
            let url = app.appendingPathComponent("Contents/Resources/Cat_Sprite_Sheet.png")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private struct RGB: Hashable {
        let r: UInt8, g: UInt8, b: UInt8
    }

    private func loadFrames(theme name: String) {
        guard let url = Self.spriteURL(), let source = NSImage(contentsOf: url)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            frames = []
            return
        }
        theme = name
        let outline = RGB(r: 47, g: 47, b: 46), fur = RGB(r: 224, g: 224, b: 224), shade = RGB(r: 181, g: 181, b: 181)
        let map: [RGB: RGB]
        switch name {
        case "ginger": map = [fur: RGB(r: 247, g: 172, b: 98), shade: RGB(r: 214, g: 122, b: 60), outline: RGB(r: 66, g: 38, b: 26)]
        case "cream": map = [fur: RGB(r: 252, g: 238, b: 214), shade: RGB(r: 226, g: 196, b: 152), outline: RGB(r: 74, g: 58, b: 44)]
        case "blue": map = [fur: RGB(r: 170, g: 182, b: 204), shade: RGB(r: 128, g: 140, b: 166), outline: RGB(r: 38, g: 42, b: 58)]
        case "calico": map = [fur: RGB(r: 250, g: 246, b: 238), shade: RGB(r: 222, g: 150, b: 84), outline: RGB(r: 48, g: 40, b: 36)]
        default: map = [:]
        }

        let w = source.width, h = source.height
        guard let ctx = Self.bitmap(w, h), let data = ctx.data else { frames = []; return }
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        if !map.isEmpty {
            let p = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
            for i in stride(from: 0, to: w * h * 4, by: 4) where p[i + 3] == 255 {
                for (from, to) in map where abs(Int(p[i]) - Int(from.r)) <= 6
                    && abs(Int(p[i + 1]) - Int(from.g)) <= 6 && abs(Int(p[i + 2]) - Int(from.b)) <= 6 {
                    p[i] = to.r; p[i + 1] = to.g; p[i + 2] = to.b
                    break
                }
            }
        }
        guard let image = ctx.makeImage() else { frames = []; return }
        let size = Self.frameSize
        var rows = (0..<(h / size)).map { r in
            (0..<(w / size)).compactMap { c in
                image.cropping(to: CGRect(x: c * size, y: r * size, width: size, height: size))
            }
        }
        // Row 10: the sitting frames with closed eyes and a blush.
        let line = map[outline] ?? outline
        if let sitting = rows.first {
            rows.append(sitting.compactMap { frame -> CGImage? in
                guard let c = Self.bitmap(size, size), let d = c.data else { return nil }
                c.draw(frame, in: CGRect(x: 0, y: 0, width: size, height: size))
                let p = d.bindMemory(to: UInt8.self, capacity: size * size * 4)
                func put(_ x: Int, _ y: Int, _ rgb: RGB) {
                    let i = (y * size + x) * 4
                    p[i] = rgb.r; p[i + 1] = rgb.g; p[i + 2] = rgb.b; p[i + 3] = 255
                }
                let blush = RGB(r: 222, g: 117, b: 134)
                put(15, 23, line); put(16, 23, line)
                put(15, 24, blush); put(19, 24, blush)
                return c.makeImage()
            })
        }
        frames = rows
    }

    private static func bitmap(_ w: Int, _ h: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
