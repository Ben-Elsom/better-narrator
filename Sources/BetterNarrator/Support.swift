import AppKit
import Foundation

// MARK: - Logging

enum Log {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        return dir.appendingPathComponent("BetterNarrator.log")
    }()
    private static let queue = DispatchQueue(label: "log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    static func reset() {
        queue.sync { try? "".write(to: url, atomically: true, encoding: .utf8) }
    }
}

// MARK: - Settings

struct VoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let accent: String
}

final class Settings: ObservableObject {
    static let shared = Settings()

    static let voices: [VoiceOption] = [
        VoiceOption(id: "af_heart", name: "Heart", accent: "American"),
        VoiceOption(id: "af_bella", name: "Bella", accent: "American"),
        VoiceOption(id: "af_nicole", name: "Nicole", accent: "American"),
        VoiceOption(id: "af_sarah", name: "Sarah", accent: "American"),
        VoiceOption(id: "af_aoede", name: "Aoede", accent: "American"),
        VoiceOption(id: "af_kore", name: "Kore", accent: "American"),
        VoiceOption(id: "am_michael", name: "Michael", accent: "American"),
        VoiceOption(id: "am_fenrir", name: "Fenrir", accent: "American"),
        VoiceOption(id: "am_puck", name: "Puck", accent: "American"),
        VoiceOption(id: "bf_emma", name: "Emma", accent: "British"),
        VoiceOption(id: "bf_isabella", name: "Isabella", accent: "British"),
        VoiceOption(id: "bm_george", name: "George", accent: "British"),
        VoiceOption(id: "bm_fable", name: "Fable", accent: "British"),
    ]
    static let speeds: [Double] = [1.0, 1.25, 1.5, 2.0]

    @Published var voice: String {
        didSet { UserDefaults.standard.set(voice, forKey: "voice") }
    }
    @Published var speed: Double {
        didSet { UserDefaults.standard.set(speed, forKey: "speed") }
    }
    let skipSeconds: Double = 15
    /// Off by default: Read just starts talking, and the window opens from the menu bar.
    /// On/Off for the whole app. Off: no voice engine, no watching copies or highlights.
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "enabled") }
    }
    @Published var showWindowOnRead: Bool {
        didSet { UserDefaults.standard.set(showWindowOnRead, forKey: "showWindowOnRead") }
    }

    private init() {
        voice = UserDefaults.standard.string(forKey: "voice") ?? "af_heart"
        let s = UserDefaults.standard.double(forKey: "speed")
        speed = s > 0 ? s : 1.0
        showWindowOnRead = UserDefaults.standard.bool(forKey: "showWindowOnRead")
        enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
    }

    var voiceName: String {
        Settings.voices.first { $0.id == voice }?.name ?? voice
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Formatting

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds.rounded(.down))
    if s >= 3600 {
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    return String(format: "%d:%02d", s / 60, s % 60)
}

func formatSpeed(_ speed: Double) -> String {
    speed == speed.rounded() ? "\(Int(speed))×" : "\(speed)×"
}

extension Bundle {
    var resourceURL_: URL { resourceURL ?? bundleURL }
}
