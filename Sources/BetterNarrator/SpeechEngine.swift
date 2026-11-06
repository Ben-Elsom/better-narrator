import Foundation

/// Runs the Kokoro engine (engine/narrator_engine.py) as a helper process and
/// talks to it with one JSON message per line.
final class SpeechEngine: ObservableObject {
    enum Status: Equatable { case starting, ready, failed(String) }

    @Published private(set) var status: Status = .starting

    struct SegmentAudio {
        let index: Int
        let samples: [Float]
        let words: [(charStart: Int, charEnd: Int, start: Double, end: Double)]
        let genSeconds: Double
    }

    var onSegment: ((String, SegmentAudio) -> Void)?
    var onJobDone: ((String) -> Void)?

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private let parseQueue = DispatchQueue(label: "engine.parse")
    private var restarts = 0
    private var stopping = false

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Better Narrator")
    }

    func start() {
        stopping = false
        let python = SpeechEngine.supportDirectory.appendingPathComponent("engine-venv/bin/python")
        let resources = Bundle.main.resourceURL_
        let script = resources.appendingPathComponent("engine/narrator_engine.py")
        let models = resources.appendingPathComponent("models")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            status = .failed("The voice engine isn't installed. Run scripts/build_app.sh again.")
            Log.info("engine python missing at \(python.path)")
            return
        }
        let p = Process()
        p.executableURL = python
        p.arguments = ["-I", script.path, models.path]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        var cores: Int32 = 4
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.physicalcpu", &cores, &size, nil, 0)
        env["BN_THREADS"] = String(max(1, cores))
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            self?.parseQueue.async { self?.consume(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                let lines = s.split(separator: "\n").filter { !$0.contains("Warning") && !$0.contains("warn(") }
                for l in lines.prefix(5) { Log.info("engine stderr: \(l)") }
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.handleExit(code: proc.terminationStatus) }
        }
        do {
            try p.run()
            process = p
            stdin = inPipe.fileHandleForWriting
            status = .starting
            Log.info("engine started pid \(p.processIdentifier)")
        } catch {
            status = .failed("Couldn't start the voice engine: \(error.localizedDescription)")
        }
    }

    func stop() {
        stopping = true
        send(["cmd": "quit"])
        try? stdin?.close()
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { if p?.isRunning == true { p?.terminate() } }
    }

    private func handleExit(code: Int32) {
        Log.info("engine exited with \(code)")
        process = nil
        stdin = nil
        guard !stopping else { return }
        if restarts < 3 {
            restarts += 1
            status = .starting
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }
        } else {
            status = .failed("The voice engine keeps stopping. Check ~/Library/Logs/BetterNarrator.log.")
        }
    }

    // MARK: - Requests

    func synthesize(job: String, voice: String, segments: [Segment]) {
        let segs: [[String: Any]] = segments.map { ["i": $0.index, "text": $0.speech, "pause": $0.pause] }
        send(["cmd": "synth", "job": job, "voice": voice, "segments": segs])
    }

    func focus(job: String) { send(["cmd": "focus", "job": job]) }
    func cancel(job: String) { send(["cmd": "cancel", "job": job]) }

    private func send(_ obj: [String: Any]) {
        guard let stdin, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var line = data
        line.append(0x0A)
        do { try stdin.write(contentsOf: line) } catch { Log.info("engine write failed: \(error)") }
    }

    // MARK: - Responses

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "ready":
            DispatchQueue.main.async { self.status = .ready; self.restarts = 0 }
            Log.info("engine ready")
        case "segment":
            guard let job = obj["job"] as? String, let i = obj["i"] as? Int,
                  let b64 = obj["audio"] as? String, let raw = Data(base64Encoded: b64) else { return }
            let samples: [Float] = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let words = (obj["words"] as? [[Double]] ?? []).compactMap { w -> (Int, Int, Double, Double)? in
                w.count == 4 ? (Int(w[0]), Int(w[1]), w[2], w[3]) : nil
            }
            let seg = SegmentAudio(index: i, samples: samples, words: words.map { ($0.0, $0.1, $0.2, $0.3) },
                                   genSeconds: obj["gen_seconds"] as? Double ?? 0)
            DispatchQueue.main.async { self.onSegment?(job, seg) }
        case "job_done":
            if let job = obj["job"] as? String { DispatchQueue.main.async { self.onJobDone?(job) } }
        case "error":
            Log.info("engine error: \(obj["message"] ?? "")")
            if obj["job"] == nil, let msg = obj["message"] as? String, msg.hasPrefix("Could not load") {
                DispatchQueue.main.async { self.status = .failed(msg) }
            }
        default:
            break
        }
    }
}
