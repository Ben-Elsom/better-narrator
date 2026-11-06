import AppKit
import SwiftUI

struct ReaderView: View {
    @ObservedObject var session: ReadingSession
    @ObservedObject var settings = Settings.shared

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                TranscriptView(session: session)
                if session.hasStarted && !session.following {
                    JumpToLiveButton { session.following = true }
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: session.following)
            TransportBar(session: session)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: 520, minHeight: 420)
    }
}

struct JumpToLiveButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 12, weight: .semibold))
                Text("Jump to Live")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.accentColor))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("l", modifiers: .command)
        .help("Scroll back to the word being read (⌘L)")
    }
}

// MARK: - Transport

struct TransportBar: View {
    @ObservedObject var session: ReadingSession
    @ObservedObject var settings = Settings.shared

    var body: some View {
        VStack(spacing: 8) {
            Scrubber(position: session.position, generated: session.generated,
                     total: max(session.estimatedTotal, session.generated, 0.01)) { t in
                session.seek(to: t)
            }
            HStack {
                Text(formatTime(session.position))
                Spacer()
                Text(statusText)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(remainingText)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                voiceMenu
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 26) {
                    TransportIconButton(symbol: "gobackward.15", size: 20, help: "Back 15 seconds (←)") {
                        session.skip(by: -settings.skipSeconds)
                    }
                    .disabled(!session.hasStarted && session.position == 0)
                    PlayButton(session: session)
                    TransportIconButton(symbol: "goforward.15", size: 20, help: "Forward 15 seconds (→)") {
                        session.skip(by: settings.skipSeconds)
                    }
                    .disabled(session.generated - session.position < 1)
                }
                speedMenu
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var statusText: String {
        switch session.state {
        case .preparing: return "Preparing audio… \(Int(session.readiness * 100))%"
        case .ready: return "Ready"
        case .buffering: return "Catching up…"
        case .finished: return "Finished"
        case .playing, .paused:
            return session.generationComplete ? "" : "\(formatTime(session.generated)) ready"
        }
    }

    private var remainingText: String {
        let remaining = max(0, session.estimatedTotal - session.position)
        return "-" + formatTime(remaining)
    }

    private var voiceMenu: some View {
        Menu {
            ForEach(["American", "British"], id: \.self) { accent in
                Section(accent) {
                    ForEach(Settings.voices.filter { $0.accent == accent }) { v in
                        Button {
                            settings.voice = v.id
                        } label: {
                            if v.id == settings.voice { Label(v.name, systemImage: "checkmark") } else { Text(v.name) }
                        }
                    }
                }
            }
            Divider()
            Text("New voices apply to the next reading")
        } label: {
            Label(Settings.voices.first { $0.id == session.voice }?.name ?? "Voice", systemImage: "person.wave.2")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Voice")
    }

    private var speedMenu: some View {
        Menu {
            ForEach(Settings.speeds, id: \.self) { s in
                Button {
                    settings.speed = s
                } label: {
                    if s == settings.speed { Label(formatSpeed(s), systemImage: "checkmark") } else { Text(formatSpeed(s)) }
                }
            }
        } label: {
            Text(formatSpeed(settings.speed))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Playback speed")
    }
}

struct TransportIconButton: View {
    let symbol: String
    let size: CGFloat
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.5))
        .help(help)
    }
}

struct PlayButton: View {
    @ObservedObject var session: ReadingSession

    var body: some View {
        Button {
            session.togglePlay()
        } label: {
            ZStack {
                Circle()
                    .fill(enabled ? Color.accentColor : Color.secondary.opacity(0.18))
                    .frame(width: 46, height: 46)
                if session.state == .preparing {
                    Circle()
                        .trim(from: 0, to: max(0.03, session.readiness))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 46, height: 46)
                        .animation(.easeOut(duration: 0.3), value: session.readiness)
                }
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(enabled ? Color.white : Color.secondary)
                    .offset(x: symbol == "play.fill" ? 1.5 : 0)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(helpText)
    }

    private var enabled: Bool { session.state != .preparing }

    private var symbol: String {
        switch session.state {
        case .playing, .buffering: return "pause.fill"
        case .finished: return "arrow.counterclockwise"
        case .preparing: return "hourglass"
        default: return "play.fill"
        }
    }

    private var helpText: String {
        switch session.state {
        case .preparing: return "Preparing enough audio to play smoothly"
        case .playing, .buffering: return "Pause (Space)"
        case .finished: return "Play again"
        default: return "Start (Space)"
        }
    }
}

/// A thin progress track: played portion, audio ready so far, and the rest.
struct Scrubber: View {
    let position: Double
    let generated: Double
    let total: Double
    let onSeek: (Double) -> Void
    @State private var dragging: Double?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let shown = dragging ?? position
            let played = CGFloat(min(1, shown / total)) * w
            let ready = CGFloat(min(1, generated / total)) * w
            let height: CGFloat = hovering || dragging != nil ? 7 : 5
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.16))
                Capsule().fill(Color.secondary.opacity(0.28)).frame(width: max(height, ready))
                Capsule().fill(Color.accentColor).frame(width: max(height, played))
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in dragging = min(generated, max(0, Double(v.location.x / w) * total)) }
                    .onEnded { v in
                        let t = min(generated, max(0, Double(v.location.x / w) * total))
                        dragging = nil
                        onSeek(t)
                    }
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: height)
        }
        .frame(height: 14)
        .help("Drag to move through the audio that's ready")
    }
}
