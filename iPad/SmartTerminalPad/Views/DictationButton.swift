import SwiftUI

/// The microphone in the terminal header. Tap to start, tap to stop (⌘⇧D as well);
/// red while recording, a spinner while the server works, and the reason when it fails.
struct DictationButton: View {
    @Bindable var model: PadModel
    let session: String

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
                    if d.state == .transcribing {
                        ProgressView().controlSize(.small).tint(Theme.selection)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(tint)
                            .symbolEffect(.pulse, options: .repeating, isActive: d.state == .recording)
                    }
                }
                .frame(width: 36, height: 32)
            }
            .buttonStyle(.plain)
            .glassEffect(d.state == .recording ? .regular.tint(.red.opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .accessibilityLabel(d.state == .recording ? "Stop dictation" : "Dictate")
        }
        .animation(.easeInOut(duration: 0.2), value: d.state)
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
