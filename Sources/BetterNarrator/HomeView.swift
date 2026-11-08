import AppKit
import SwiftUI

/// The window you see when you open Better Narrator with nothing being read.
struct HomeView: View {
    @ObservedObject var engine: SpeechEngine
    @ObservedObject var settings = Settings.shared
    @ObservedObject var permissions = Permissions.shared
    @ObservedObject var history = History.shared
    let readClipboard: () -> Void
    let readAgain: (History.Item) -> Void

    private var canRead: Bool { engine.status == .ready && settings.enabled }

    var body: some View {
        VStack(spacing: 16) {
            header

            if !permissions.accessibility { permissionCard }

            if history.items.isEmpty { steps } else { recent }

            Button(action: readClipboard) {
                Label("Read Clipboard Now", systemImage: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canRead)

            HStack(alignment: .center) {
                Picker("Voice", selection: $settings.voice) {
                    ForEach(Settings.voices) { v in Text("\(v.name) (\(v.accent))").tag(v.id) }
                }
                .fixedSize()
                Spacer()
                Text("Speed").foregroundStyle(.secondary)
                SpeedWheel().frame(width: 170, height: 40)
            }
            .font(.system(size: 12))

            Text("Highlight or copy text anywhere, then tap Read on the Touch Bar. ⌃⌥R reads a highlight straight away.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 26)
        .padding(.top, 34)
        .padding(.bottom, 20)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text("Better Narrator").font(.system(size: 22, weight: .bold))
                statusPill
            }
            Spacer()
            Toggle(isOn: $settings.enabled) {
                Text(settings.enabled ? "On" : "Off").font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.switch)
            .help("Off stops the voice engine and stops watching copies and highlights, so it uses no power.")
        }
    }

    private var permissionCard: some View {
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
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.35)))
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 14) {
            Step(number: 1, title: permissions.accessibility ? "Highlight or copy some text" : "Copy some text",
                 detail: permissions.accessibility
                    ? "Highlight a paragraph in Claude (or any app), or use Claude's Copy button."
                    : "Use Claude's Copy button, or highlight a paragraph and press ⌘C.")
            Step(number: 2, title: "Tap Read on the Touch Bar",
                 detail: "It appears on the far right for 10 seconds.")
            Step(number: 3, title: "Listen",
                 detail: "Use −15, play and +15 on the Touch Bar, and slide the wheel to change speed. The page button shows the text with the blue highlight.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.045)))
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recently read")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(history.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 46) }
                    HistoryRow(item: item, canRead: canRead, play: { readAgain(item) }, remove: { history.remove(item) })
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
        }
    }

    @ViewBuilder private var statusPill: some View {
        HStack(spacing: 7) {
            switch engine.status {
            case .starting:
                ProgressView().controlSize(.small)
                Text("Warming up the voice…")
            case .ready:
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Ready")
            case .off:
                Circle().fill(Color.secondary).frame(width: 8, height: 8)
                Text("Off: using no power")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(2)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
    }
}

private struct HistoryRow: View {
    let item: History.Item
    let canRead: Bool
    let play: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(canRead ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canRead)
            .help("Read this again")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 13)).lineLimit(1)
                Text(item.date, format: .relative(presentation: .named))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if hovering {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove from history")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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
