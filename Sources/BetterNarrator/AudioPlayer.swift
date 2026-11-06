import AVFoundation

/// Plays a growing list of samples from any point, at any speed, without
/// changing pitch. New audio can be added while it plays.
final class AudioPlayer {
    static let sampleRate: Double = 24_000

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: AudioPlayer.sampleRate, channels: 1)!

    private(set) var isPlaying = false
    private var startSample = 0
    private var scheduledEnd = 0
    private var token = 0

    /// Called on the main thread when every scheduled sample has been heard.
    var onDrained: ((Int) -> Void)?

    init() {
        engine.attach(node)
        engine.attach(pitch)
        engine.connect(node, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        pitch.overlap = 8
        engine.prepare()
    }

    var rate: Double {
        get { Double(pitch.rate) }
        set { pitch.rate = Float(newValue) }
    }

    /// Where playback is right now, in samples from the start of the reading.
    var currentSample: Int {
        guard isPlaying, let t = node.lastRenderTime, let pt = node.playerTime(forNodeTime: t) else { return startSample }
        return min(scheduledEnd, startSample + max(0, Int(pt.sampleTime)))
    }

    func play(_ samples: [Float], from sample: Int) {
        halt()
        token += 1
        startSample = max(0, min(sample, samples.count))
        scheduledEnd = startSample
        if !engine.isRunning {
            do { try engine.start() } catch { Log.info("audio engine failed: \(error)"); return }
        }
        isPlaying = true
        schedule(samples)
        node.play()
    }

    /// Schedules any samples added since the last call.
    func schedule(_ samples: [Float]) {
        guard isPlaying, samples.count > scheduledEnd else { return }
        let chunk = Int(AudioPlayer.sampleRate * 20)
        var from = scheduledEnd
        while from < samples.count {
            let to = min(samples.count, from + chunk)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(to - from)) else { return }
            buf.frameLength = AVAudioFrameCount(to - from)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress! + from, count: to - from)
            }
            let t = token, end = to
            node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.token == t, self.isPlaying, end == self.scheduledEnd else { return }
                    self.onDrained?(end)
                }
            }
            from = to
        }
        scheduledEnd = samples.count
    }

    /// Stops and returns the sample it stopped at.
    @discardableResult
    func pause() -> Int {
        let at = currentSample
        halt()
        startSample = at
        return at
    }

    private func halt() {
        token += 1
        isPlaying = false
        node.stop()
    }

    func shutdown() {
        halt()
        engine.stop()
    }
}
