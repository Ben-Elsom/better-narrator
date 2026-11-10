import AppKit
import SwiftUI

/// A camera-style ruler for playback speed: the ticks slide under a fixed green
/// marker. Drag or flick it on the Touch Bar, or drag and scroll it in a window.
/// 1× to 5×, in steps of 0.1.
final class SpeedWheelView: NSView {
    static let range: ClosedRange<Double> = 1...5

    var onChange: ((Double) -> Void)?
    private let stepWidth: CGFloat
    private let isTouchBar: Bool
    private var exact: Double = 1      // where the ruler really is, between ticks
    private var lastX: CGFloat?
    private var velocity: Double = 0   // speed units per second, for the flick
    private var lastMoveTime: TimeInterval = 0
    private var momentum: Timer?

    /// When true, the marker keeps its usual distance from the right edge and the left side
    /// is cut short instead, so the wheel can give up room (to the Read button) without
    /// the rest of the bar changing.
    var trimsLeft = false {
        didSet { if trimsLeft != oldValue { needsDisplay = true } }
    }
    /// Half the wheel's width the last time it was laid out untrimmed: how far the
    /// ticks reach to the right of the marker.
    private var fullReach: CGFloat = 0
    /// Room kept left of the marker even when trimmed, for the bold current speed and a few slower ticks.
    private let minLeft: CGFloat = 24

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !trimsLeft { fullReach = newSize.width / 2 }
    }

    /// Where the fixed green marker sits.
    private var markerX: CGFloat {
        let mid = bounds.midX
        guard trimsLeft, fullReach > 0 else { return mid }
        return min(mid, max(minLeft, bounds.width - fullReach))
    }

    var value: Double = 1 {
        didSet {
            guard value != oldValue else { return }
            if lastX == nil && momentum == nil { exact = value }
            needsDisplay = true
        }
    }

    init(touchBar: Bool) {
        isTouchBar = touchBar
        stepWidth = touchBar ? 9 : 10
        super.init(frame: NSRect(x: 0, y: 0, width: touchBar ? 190 : 170, height: touchBar ? 30 : 40))
        if touchBar { allowedTouchTypes = [.direct] }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Height only: whoever hosts the wheel decides how wide it is.
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: frame.height) }
    override var isFlipped: Bool { false }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height, mid = markerX
        // Ticks fade by the same distance on both sides, so a trimmed wheel looks like the
        // full one with its left end cut off.
        let reach = max(1, bounds.width - mid)
        let labelHeight: CGFloat = isTouchBar ? 11 : 14
        let tickBottom = labelHeight + 1
        let tickTop = h - (isTouchBar ? 7 : 9)
        let ink: NSColor = isTouchBar ? .white : .labelColor
        let green = NSColor.systemGreen

        for tenth in 10...50 {
            let v = Double(tenth) / 10
            let x = mid + CGFloat((v - exact) * 10) * stepWidth
            guard x > -2, x < bounds.width + 2, abs(x - mid) > 1 else { continue }
            let fade = max(0.12, 1 - abs(x - mid) / reach)
            let major = tenth % 5 == 0
            let height = (tickTop - tickBottom) * (major ? 1 : 0.68)
            let y = tickBottom + (tickTop - tickBottom - height) / 2
            ink.withAlphaComponent(fade * (major ? 0.95 : 0.6)).setFill()
            NSRect(x: x - 0.75, y: y, width: 1.5, height: height).fill()
            if major && abs(x - mid) > 22 {
                draw(label(v), at: x, height: labelHeight, color: ink.withAlphaComponent(fade * 0.65), bold: false)
            }
        }

        // The fixed marker.
        green.setFill()
        NSRect(x: mid - 1, y: tickBottom, width: 2, height: tickTop - tickBottom).fill()
        let t = NSBezierPath()
        let tw: CGFloat = isTouchBar ? 5 : 7, tt = h - 0.5, tb = tickTop + 0.5
        t.move(to: NSPoint(x: mid - tw, y: tt))
        t.line(to: NSPoint(x: mid + tw, y: tt))
        t.line(to: NSPoint(x: mid, y: tb))
        t.close()
        t.fill()
        draw(label(value), at: mid, height: labelHeight, color: ink, bold: true)
    }

    private func label(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private func draw(_ text: String, at x: CGFloat, height: CGFloat, color: NSColor, bold: Bool) {
        let size: CGFloat = isTouchBar ? 9.5 : 11
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .bold : .medium),
            .foregroundColor: color,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let w = s.size().width
        s.draw(at: NSPoint(x: x - w / 2, y: (height - s.size().height) / 2))
    }

    // MARK: - Moving

    private func beginDrag(at x: CGFloat) {
        momentum?.invalidate()
        momentum = nil
        lastX = x
        velocity = 0
        lastMoveTime = ProcessInfo.processInfo.systemUptime
    }

    private func drag(to x: CGFloat) {
        guard let last = lastX else { return }
        // Dragging left pulls higher speeds under the marker.
        let delta = Double(last - x) / Double(stepWidth) / 10
        lastX = x
        let now = ProcessInfo.processInfo.systemUptime
        let dt = max(0.001, now - lastMoveTime)
        lastMoveTime = now
        velocity = velocity * 0.6 + (delta / dt) * 0.4
        move(by: delta)
    }

    private func endDrag() {
        lastX = nil
        if ProcessInfo.processInfo.systemUptime - lastMoveTime > 0.08 { velocity = 0 }
        guard abs(velocity) > 0.4 else { settle(); return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.velocity *= 0.9
            self.move(by: self.velocity / 30)
            if abs(self.velocity) < 0.25 {
                t.invalidate()
                self.momentum = nil
                self.settle()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        momentum = timer
    }

    private func move(by delta: Double) {
        exact = min(SpeedWheelView.range.upperBound, max(SpeedWheelView.range.lowerBound, exact + delta))
        let snapped = (exact * 10).rounded() / 10
        if snapped != value {
            value = snapped
            onChange?(snapped)
        }
        needsDisplay = true
    }

    private func settle() {
        exact = value
        needsDisplay = true
    }

    // MARK: - Input

    override func touchesBegan(with event: NSEvent) {
        if let t = event.touches(matching: .began, in: self).first { beginDrag(at: t.location(in: self).x) }
    }
    override func touchesMoved(with event: NSEvent) {
        if let t = event.touches(matching: .moved, in: self).first { drag(to: t.location(in: self).x) }
    }
    override func touchesEnded(with event: NSEvent) { endDrag() }
    override func touchesCancelled(with event: NSEvent) { endDrag() }

    override func mouseDown(with event: NSEvent) { beginDrag(at: convert(event.locationInWindow, from: nil).x) }
    override func mouseDragged(with event: NSEvent) { drag(to: convert(event.locationInWindow, from: nil).x) }
    override func mouseUp(with event: NSEvent) { endDrag() }
    override func scrollWheel(with event: NSEvent) {
        let d = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        move(by: -Double(d) / Double(stepWidth) / 10)
        if event.phase == .ended || event.momentumPhase == .ended { settle() }
    }
}

/// The wheel for SwiftUI windows, tied to the shared speed setting.
struct SpeedWheel: NSViewRepresentable {
    @ObservedObject var settings = Settings.shared

    func makeNSView(context: Context) -> SpeedWheelView {
        let v = SpeedWheelView(touchBar: false)
        v.value = settings.speed
        v.onChange = { Settings.shared.speed = $0 }
        v.toolTip = "Playback speed, 1× to 5×. Drag or scroll."
        return v
    }

    func updateNSView(_ v: SpeedWheelView, context: Context) { v.value = settings.speed }
}
