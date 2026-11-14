import SwiftUI

/// The microphone in the key bar under the terminal. Tap to start, tap to stop (⌘⇧D as well);
/// red while recording, a spinner while the server works, and the reason when it fails.
struct DictationButton: View {
    @Bindable var model: PadModel
    let session: String
    /// The key bar's big mic; the plain size elsewhere.
    var large = false

    var body: some View {
        let d = model.dictation
        HStack(spacing: 8) {
            if case .failed(let message) = d.state {
                Text(message)
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.trailing)
                    .frame(maxWidth: 360, alignment: .trailing)
                    .transition(.opacity)
            }
            Button { model.dictate(session) } label: {
                ZStack {
                    if d.state == .transcribing || isComposing {
                        ProgressView().controlSize(.small).tint(Theme.selection)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: large ? 20 : 15, weight: .medium))
                            .foregroundStyle(tint)
                            .symbolEffect(.pulse, options: .repeating, isActive: d.state == .recording)
                    }
                }
                .frame(width: large ? 64 : 36, height: large ? 44 : 32)
            }
            .buttonStyle(.plain)
            .glassEffect(d.state == .recording ? .regular.tint(.red.opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
            // Command mode (a plain shell): a badge on the button's corner, the mic stays plain.
            .overlay(alignment: .topTrailing) {
                if commands {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: large ? 9 : 7, weight: .bold))
                        .foregroundStyle(Theme.onSelection)
                        .frame(width: large ? 18 : 14, height: large ? 18 : 14)
                        .background(Theme.selection, in: .circle)
                        .overlay(Circle().stroke(Theme.bar, lineWidth: 1.5))
                        .offset(x: 3, y: -3)
                        .allowsHitTesting(false)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .accessibilityLabel(d.state == .recording ? "Stop" : commands ? "Voice command" : "Dictate")
        }
        .animation(.easeInOut(duration: 0.2), value: d.state)
    }

    private var commands: Bool { model.voiceCommands(in: session) }

    private var isComposing: Bool {
        if case .composing = model.dictation.state { return true }
        return false
    }

    private var icon: String {
        switch model.dictation.state {
        case .recording: "mic.fill"
        case .failed: "mic.slash"
        default: "mic"
        }
    }

    private var tint: Color {
        switch model.dictation.state {
        case .recording: .red
        case .failed: .orange
        case .starting: .secondary
        default: .primary
        }
    }
}
