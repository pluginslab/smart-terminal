import SwiftUI
import UIKit

/// Setting up iSH+'s Linux as a second host: an SSH server and tmux in the running
/// distribution, this device's key in its authorized_keys, and the user name. iSH+
/// forwards the guest's port 22 to this device's 127.0.0.1 (or 10022), so the app
/// reaches it as it reaches supermaschine. Done once per distribution.
struct IshSetupView: View {
    @Bindable var model: PadModel
    @Environment(\.dismiss) private var dismiss
    @State private var user = ""
    @State private var port = ""
    @State private var copied = false

    private var ish: Host { model.ish }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Circle().fill(stateColor).frame(width: 8, height: 8)
                        Text(stateText)
                    }
                    if case .failed(let m) = ish.state, model.ishConfigured {
                        Text(m).font(.footnote).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("iSH+ runs one distribution at a time; the one running is the one listed. Turn on Keep Running in Background in iSH+'s settings, or iOS pauses Linux while you're here.")
                }

                Section {
                    Text(script)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = script
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Commands", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button {
                        UIApplication.shared.open(URL(string: "ishplus://")!)
                    } label: {
                        Label("Open iSH+", systemImage: "arrow.up.forward.app")
                    }
                } header: {
                    Text("1. Run this in iSH+")
                } footer: {
                    Text("Installs an SSH server and tmux (apt, apk, dnf, pacman, zypper or xbps), starts it at boot, and adds this \(UIDevice.current.model)'s key. It asks for your password once, for sudo.")
                }

                Section {
                    TextField("Your user in that distribution", text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .onSubmit(connect)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                        .font(.body.monospaced())
                    Button("Connect", action: connect)
                        .disabled(user.trimmingCharacters(in: .whitespaces).isEmpty || ish.state == .connecting)
                } header: {
                    Text("2. Your user name and the port")
                } footer: {
                    Text("The account you made when setting up the distribution (`whoami` in iSH+), and the port iSH+ shows for the SSH server (Settings > Linux VM > Ports). 2222, 22, 10022 and 12222 are tried after it.")
                }
            }
            .navigationTitle("iSH+")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear { user = ish.user; port = String(model.ishPort) }
        .onChange(of: ish.state) { _, new in
            if new == .connected, model.ishConfigured { dismiss() }
        }
    }

    private func connect() {
        if let p = Int(port), p > 0, p < 65536 { model.setIshPort(p) }
        model.setIshUser(user)
        if ish.state != .connecting { ish.connect() }
    }

    private var stateText: String {
        if !model.ishConfigured { return "Not set up yet" }
        return switch ish.state {
        case .connected: "Connected to \(ish.displayName)"
        case .connecting: "Connecting…"
        case .idle: "Not running"
        case .failed: "Couldn't connect"
        }
    }

    private var stateColor: Color {
        switch ish.state {
        case .connected: .green
        case .connecting: .yellow
        default: .secondary
        }
    }

    /// One paste: whatever package manager the distribution has, then its init's way
    /// to start sshd at boot (systemd, OpenRC, runit), then the key.
    private var script: String {
        """
        sudo sh -c '
        if command -v apt-get >/dev/null; then apt-get update -q && apt-get install -yq openssh-server tmux
        elif command -v apk >/dev/null; then apk add openssh tmux
        elif command -v dnf >/dev/null; then dnf install -yq openssh-server tmux
        elif command -v pacman >/dev/null; then pacman -Sy --noconfirm openssh tmux
        elif command -v zypper >/dev/null; then zypper -nq install openssh tmux
        elif command -v xbps-install >/dev/null; then xbps-install -Sy openssh tmux
        fi
        ssh-keygen -A
        if command -v systemctl >/dev/null; then systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd
        elif command -v rc-update >/dev/null; then rc-update add sshd default; rc-service sshd start
        elif [ -d /etc/sv/sshd ]; then ln -sf /etc/sv/sshd /var/service/
        else /usr/sbin/sshd
        fi'
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        grep -qF '\(keyBody)' ~/.ssh/authorized_keys 2>/dev/null || echo '\(DeviceKey.publicKeyLine)' >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        whoami
        """
    }

    /// The key without its comment, to find it again in authorized_keys.
    private var keyBody: String {
        DeviceKey.publicKeyLine.split(separator: " ").prefix(2).joined(separator: " ")
    }
}
