import SwiftUI
import SwiftTerm

/// The terminal column: a header band like the Mac's, then the session's terminal,
/// or the setup card while the host isn't reachable.
struct DetailColumn: View {
    @Bindable var model: PadModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if case .connected = model.host.state, let name = model.selected,
                   model.sessions.contains(where: { $0.name == name }) {
                    TerminalHost(model: model, session: name).id(name)
                } else if case .connected = model.host.state {
                    ContentUnavailableView("No Session", systemImage: "terminal",
                                           description: Text("Pick a session, or press ⌘T for a new one."))
                } else {
                    ConnectCard(host: model.host)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: Theme.background))
        }
        .background(Theme.head.ignoresSafeArea())
        .alert("Rename", isPresented: renamingBinding) {
            RenameField(model: model)
        }
    }

    private var header: some View {
        let s = model.sessions.first { $0.name == model.selected }
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                if let s {
                    Text(model.title(of: s)).font(.title3.weight(.bold)).lineLimit(1).truncationMode(.middle)
                    Text(s.path.replacingOccurrences(of: "/home/\(model.host.user)", with: "~"))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                } else {
                    Text(model.host.displayName).font(.title3.weight(.bold))
                }
            }
            Spacer(minLength: 8)
            if let s {
                Button { model.close(s.name) } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .medium)).frame(width: 36, height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .keyboardShortcut("w", modifiers: .command)
            }
        }
        .padding(.leading, 20).padding(.trailing, 12)
        .frame(height: 64)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.line) }
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })
    }
}

private struct RenameField: View {
    let model: PadModel
    @State private var text = ""

    var body: some View {
        TextField("Name", text: $text)
            .onAppear { text = current }
        Button("Save") { commit() }
        Button("Cancel", role: .cancel) { model.renaming = nil }
    }

    private var groupID: UUID? {
        guard let r = model.renaming, r.hasPrefix("group:") else { return nil }
        return UUID(uuidString: String(r.dropFirst(6)))
    }

    private var current: String {
        if let g = groupID { return model.groups.first { $0.id == g }?.name ?? "" }
        guard let r = model.renaming, let s = model.sessions.first(where: { $0.name == r }) else { return "" }
        return model.title(of: s)
    }

    private func commit() {
        if let g = groupID { model.updateGroup(g, name: text) }
        else if let r = model.renaming { model.rename(r, to: text) }
        model.renaming = nil
    }
}

/// The SwiftTerm view for one session, attached when shown.
private struct TerminalHost: UIViewRepresentable {
    let model: PadModel
    let session: String

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = Theme.background
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let pane = model.pane(for: session)
        if pane.view.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            pane.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(pane.view)
            NSLayoutConstraint.activate([
                pane.view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
                pane.view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
                pane.view.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
                pane.view.bottomAnchor.constraint(equalTo: container.keyboardLayoutGuide.topAnchor),
            ])
        }
        if pane.state == .idle || pane.state == .ended, let client = model.host.client {
            if pane.state == .ended { pane.detach() }
            pane.attach(using: client)
        }
        DispatchQueue.main.async { _ = pane.view.becomeFirstResponder() }
    }
}

/// Shown until the host accepts this iPad: its public key to add, and the error.
private struct ConnectCard: View {
    let host: Host
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(statusText, systemImage: "server.rack").font(.headline)
            if case .failed(let message) = host.state {
                Text(message).foregroundStyle(.secondary)
            }
            Text("This iPad's key. Add it to ~/.ssh/authorized_keys on \(host.displayName):")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(DeviceKey.publicKeyLine)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
            HStack {
                Button(copied ? "Copied" : "Copy Key") {
                    UIPasteboard.general.string = DeviceKey.publicKeyLine
                    copied = true
                }
                Button("Connect") { host.connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(host.state == .connecting)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(28)
    }

    private var statusText: String {
        switch host.state {
        case .idle: "Not connected to \(host.displayName)"
        case .connecting: "Connecting to \(host.displayName)…"
        case .connected: "Connected"
        case .failed: "Couldn't connect to \(host.displayName)"
        }
    }
}
