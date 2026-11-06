import AppKit
import Combine

struct TimedWord {
    let range: NSRange
    let start: Double
    let end: Double
}

/// One piece of text being read aloud: its audio as it arrives, where playback
/// is, and which word to highlight.
final class ReadingSession: ObservableObject, Identifiable {
    enum State: Equatable { case preparing, ready, playing, paused, buffering, finished }

    let id = UUID()
    let document: ReadingDocument
    let voice: String
    var jobID: String { id.uuidString }

    @Published private(set) var state: State = .preparing
    @Published private(set) var position: Double = 0
    @Published private(set) var generated: Double = 0
    @Published private(set) var estimatedTotal: Double = 0
    @Published private(set) var generationComplete = false
    @Published private(set) var readiness: Double = 0
    @Published private(set) var currentWord: TimedWord?
    @Published private(set) var currentSegmentRange: NSRange?
    @Published var following = true

    var hasStarted: Bool { state != .preparing && state != .ready }
    var isPlaying: Bool { state == .playing }
    var canStart: Bool { readiness >= 1 }

    private(set) var samples: [Float] = []
    private(set) var words: [TimedWord] = []
    private var segmentTimes: [(range: NSRange, start: Double, end: Double)] = []
    private var charsGenerated = 0
    private let totalChars: Int
    private var genRate: Double = 1.3         // seconds of audio made per second, measured as we go
    private var secondsPerChar: Double = 0.068 // refined from real audio
    private let player = AudioPlayer()
    private var ticker: Timer?
    private var settingsSub: AnyCancellable?
    var onStateChange: (() -> Void)?

    init(document: ReadingDocument, voice: String) {
        self.document = document
        self.voice = voice
        totalChars = document.segments.reduce(0) { $0 + $1.speech.count }
        estimatedTotal = Double(totalChars) * secondsPerChar
        player.rate = Settings.shared.speed
        player.onDrained = { [weak self] end in self?.drained(at: end) }
        settingsSub = Settings.shared.$speed.dropFirst().sink { [weak self] s in
            DispatchQueue.main.async { self?.speedChanged(s) }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    deinit { ticker?.invalidate() }

    func close() {
        ticker?.invalidate()
        player.shutdown()
    }

    // MARK: - Incoming audio

    func receive(_ seg: SpeechEngine.SegmentAudio) {
        guard seg.index < document.segments.count else { return }
        let segment = document.segments[seg.index]
        let offset = Double(samples.count) / AudioPlayer.sampleRate
        samples.append(contentsOf: seg.samples)
        let duration = Double(seg.samples.count) / AudioPlayer.sampleRate
        segmentTimes.append((segment.range, offset, offset + duration))
        if segment.isCode {
            words.append(TimedWord(range: segment.range, start: offset, end: offset + duration))
        } else {
            for w in seg.words {
                let r = NSRange(location: segment.range.location + w.charStart, length: max(0, w.charEnd - w.charStart))
                guard NSMaxRange(r) <= document.text.length else { continue }
                words.append(TimedWord(range: r, start: offset + w.start, end: offset + w.end))
            }
        }
        generated = Double(samples.count) / AudioPlayer.sampleRate
        charsGenerated += segment.speech.count
        if seg.genSeconds > 0.05 {
            let r = duration / seg.genSeconds
            genRate = genRate * 0.7 + r * 0.3
        }
        if charsGenerated > 40 {
            secondsPerChar = generated / Double(charsGenerated)
        }
        let remainingChars = max(0, totalChars - charsGenerated)
        estimatedTotal = generated + Double(remainingChars) * secondsPerChar
        player.schedule(samples)
        updateReadiness()
        if state == .buffering && canStart { resume() }
    }

    func generationFinished() {
        generationComplete = true
        estimatedTotal = generated
        updateReadiness()
        if state == .buffering { resume() }
    }

    // MARK: - Readiness

    /// How much audio must be ready before playback can run to the end without
    /// catching up to the generator, at the current speed.
    private func updateReadiness() {
        let wasReady = canStart
        if generationComplete {
            readiness = samples.isEmpty ? 0 : 1
        } else if samples.isEmpty {
            readiness = 0
        } else {
            let p = Settings.shared.speed
            let r = max(0.2, genRate)
            let remaining = max(0, estimatedTotal - generated)
            // Keep a few seconds in hand, more until we've measured this Mac's speed.
            var needed = segmentTimes.count < 3 ? 4.5 : 3.0
            needed = min(needed, estimatedTotal)
            if r < p * 1.1 { needed += remaining * (p / r - 1) * 1.2 }
            let ahead = generated - position
            readiness = min(1, max(0, ahead / needed))
        }
        if state == .preparing && canStart { setState(.ready) }
        if state == .ready && !canStart && !wasReady { setState(.preparing) }
    }

    // MARK: - Controls

    func togglePlay() {
        switch state {
        case .playing: pause()
        case .buffering: pause()
        case .finished: seek(to: 0); play()
        default: play()
        }
    }

    func play() {
        guard canStart || state == .paused else { return }
        if state == .finished { position = 0 }
        if !canStart && !generationComplete {
            setState(.buffering)
            return
        }
        resume()
    }

    private func resume() {
        let from = Int(position * AudioPlayer.sampleRate)
        guard from < samples.count else {
            setState(generationComplete ? .finished : .buffering)
            return
        }
        player.rate = Settings.shared.speed
        player.play(samples, from: from)
        setState(.playing)
    }

    func pause() {
        if player.isPlaying {
            position = Double(player.pause()) / AudioPlayer.sampleRate
        }
        setState(.paused)
    }

    func skip(by seconds: Double) {
        seek(to: currentPosition + seconds)
    }

    func seek(to t: Double) {
        let limit = max(0, generated - 0.05)
        let target = min(max(0, t), limit)
        position = target
        updateWord(at: target)
        following = true
        if state == .playing {
            player.play(samples, from: Int(target * AudioPlayer.sampleRate))
        } else if state == .finished {
            setState(.paused)
        }
        updateReadiness()
        onStateChange?()
    }

    func seek(toCharacter index: Int) {
        if let w = words.first(where: { NSLocationInRange(index, $0.range) || $0.range.location >= index }) {
            seek(to: w.start)
        }
    }

    var currentPosition: Double {
        player.isPlaying ? Double(player.currentSample) / AudioPlayer.sampleRate : position
    }

    private func speedChanged(_ s: Double) {
        player.rate = s
        updateReadiness()
    }

    private func drained(at end: Int) {
        position = Double(end) / AudioPlayer.sampleRate
        player.pause()
        if generationComplete && end >= samples.count {
            setState(.finished)
        } else {
            setState(.buffering)
            Log.info("buffering at \(formatTime(position))")
        }
    }

    private func setState(_ s: State) {
        guard state != s else { return }
        Log.info("state \(state) -> \(s) at \(String(format: "%.2f", currentPosition))s")
        state = s
        onStateChange?()
    }

    // MARK: - Highlight

    private var tickCount = 0

    private func tick() {
        guard state == .playing else { return }
        tickCount += 1
        let t = currentPosition
        updateWord(at: t)          // publishes only when the word changes
        if tickCount % 3 == 0 {    // the time display only needs ~10 updates a second
            position = t
        }
        if tickCount % 15 == 0 { updateReadiness() }
    }

    private func updateWord(at t: Double) {
        // Last word that has started by now.
        var lo = 0, hi = words.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if words[mid].start <= t + 0.02 { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        let w = found >= 0 ? words[found] : nil
        if w?.range != currentWord?.range { currentWord = w }
        let seg = segmentTimes.last(where: { $0.start <= t + 0.02 })?.range
        if seg != currentSegmentRange { currentSegmentRange = seg }
    }
}
