import AppKit
import SwiftUI

/// The window you see when you open Better Narrator with nothing being read.
struct HomeView: View {
    @ObservedObject var engine: SpeechEngine
    @ObservedObject var settings = Settings.shared
    @ObservedObject var permissions = Permissions.shared
    let readClipboard: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("Better Narrator")
                    .font(.system(size: 26, weight: .bold))
                statusPill
                Toggle(isOn: $settings.enabled) {
                    Text(settings.enabled ? "On" : "Off").font(.system(size: 13, weight: .semibold))
                }
                .toggleStyle(.switch)
                .help("Off stops the voice engine and stops watching copies and highlights, so it uses no power.")
            }
            .padding(.top, 34)
            .padding(.bottom, 26)

            if !permissions.accessibility {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Turn on Highlight to Read").font(.system(size: 13, weight: .semibold))
                        Text("Lets Better Narrator see the text you highlight, so you don't have to copy it. In System Settings, switch on Better Narrator under Accessibility.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Accessibility Settings…") { permissions.request() }
                            .controlSize(.small)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.35)))
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }

            VStack(alignment: .leading, spacing: 16) {
                Step(number: 1, title: permissions.accessibility ? "Highlight or copy some text" : "Copy some text",
                     detail: permissions.accessibility
                        ? "Highlight a paragraph in Claude (or any app), or use Claude's Copy button."
                        : "Use Claude's Copy button, or highlight a paragraph and press ⌘C.")
                Step(number: 2, title: "Tap Read on the Touch Bar",
                     detail: "It appears on the right for 10 seconds.")
                Step(number: 3, title: "Listen",
                     detail: "It starts talking in a few seconds. Use −15, ⏯ and +15 on the Touch Bar. To follow the blue highlight, choose Show Reading Window from the menu bar icon.")
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.045)))
            .padding(.horizontal, 28)

            Button(action: readClipboard) {
                Label("Read Clipboard Now", systemImage: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(engine.status != .ready || !settings.enabled)
            .padding(.horizontal, 28)
            .padding(.top, 22)

            HStack {
                Picker("Voice", selection: $settings.voice) {
                    ForEach(Settings.voices) { v in Text("\(v.name) (\(v.accent))").tag(v.id) }
                }
                .fixedSize()
                Spacer()
                Picker("Speed", selection: $settings.speed) {
                    ForEach(Settings.speeds, id: \.self) { s in Text(formatSpeed(s)).tag(s) }
                }
                .fixedSize()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 28)
            .padding(.top, 18)

            Text("Tip: press ⌃⌥R to read highlighted text straight away.\nBetter Narrator also lives in your menu bar. Quit it when you're done.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 24)
        }
        .frame(width: 440)
        .fixedSize()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var statusPill: some View {
        HStack(spacing: 7) {
            switch engine.status {
            case .starting:
                ProgressView().controlSize(.small)
                Text("Warming up the voice…")
            case .ready:
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Ready: copy something to begin")
            case .off:
                Circle().fill(Color.secondary).frame(width: 8, height: 8)
                Text("Off: not listening, using no power")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(2)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

private struct Step: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
