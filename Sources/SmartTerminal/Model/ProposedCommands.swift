import AppKit
import SmartTerminalCore

/// A command Claude asked you to run, typed into a tab of its own and waiting for
/// your Return. Shown as a bar over that tab's terminal.
struct ProposedCommand: Equatable {
    let id: String
    let command: String
    let reason: String?
    /// The tab of the session that asked, by its title when it was asked.
    let askedBy: String
}

/// What the tool that asked gets back.
enum ProposalStatus {
    case pending, ran(exitCode: Int, command: String, output: String), closed, typed

    var json: [String: Any] {
        switch self {
        case .pending: ["status": "pending"]
        case .ran(let code, let command, let output): ["status": "ran", "exitCode": code, "command": command, "output": output]
        case .closed: ["status": "closed"]
        case .typed: ["status": "typed"]
        }
    }
}

/// Outcomes, and the requests waiting for them (long polls on the gate).
@MainActor
final class ProposalBook {
    private(set) var outcomes: [String: ProposalStatus] = [:]
    private var waiters: [String: [(ProposalStatus) -> Void]] = [:]
    /// Proposal id → its tab.
    var tabs: [String: UUID] = [:]

    func status(_ id: String) -> ProposalStatus? { outcomes[id] ?? (tabs[id] != nil ? .pending : nil) }

    /// Calls `reply` once the proposal is settled, or after `seconds` with what there is.
    func wait(_ id: String, seconds: Double, reply: @escaping (ProposalStatus) -> Void) {
        if let done = outcomes[id] { return reply(done) }
        var answered = false
        let once: (ProposalStatus) -> Void = { s in if !answered { answered = true; reply(s) } }
        waiters[id, default: []].append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds)) { [weak self] in
            once(self?.status(id) ?? .closed)
        }
    }

    func settle(_ id: String, _ status: ProposalStatus) {
        guard outcomes[id] == nil else { return }
        outcomes[id] = status
        tabs[id] = nil
        waiters.removeValue(forKey: id)?.forEach { $0(status) }
    }
}

extension AppModel {
    /// Opens a tab after `requester` (in its group), types `command` there and shows
    /// what it's for. Returns the proposal's id, or why it can't.
    func proposeCommand(_ command: String, from requester: UUID, cwd: String?, reason: String?) -> Result<String, ProposalError> {
        if let problem = CommandProposal.problem(with: command) { return .failure(.invalid(problem)) }
        guard let wid = windowID(containingTab: requester), let asker = window(wid)?.tab(requester) else {
            return .failure(.noTab)
        }
        let id = UUID().uuidString.lowercased()
        let dir = cwd.flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            ?? sessions.currentDirectory(of: requester) ?? asker.cwd
        let tab = TerminalTab(customTitle: "Run: " + Self.short(command), cwd: dir)
        ShellIntegration.proposals[tab.id] = id
        proposals.tabs[id] = tab.id
        proposedCommands[tab.id] = ProposedCommand(id: id, command: command, reason: reason, askedBy: asker.displayTitle)
        update(wid) { $0.insert(tab, at: .afterTab(requester), select: true) }
        // Typed now, read by the shell once its prompt is up (as Resume does). No
        // Return: that one is yours.
        let session = sessions.session(for: tab.id, cwd: dir)
        session.view.send(txt: command)
        if !session.isZsh { proposals.settle(id, .typed) } // only zsh reports back
        windows?.openWindow(for: wid)
        NSApp.requestUserAttention(.informationalRequest)
        return .success(id)
    }

    /// The tab's shell reported the first command it ran (`.done` in the inbox).
    func proposalFinished(id: String, report: String) {
        guard let tabID = proposals.tabs[id] else { return }
        ShellIntegration.proposals[tabID] = nil
        proposedCommands[tabID] = nil
        let outcome = CommandProposal.parseOutcome(report) ?? .init(exitCode: -1, command: "")
        proposals.settle(id, .ran(exitCode: outcome.exitCode, command: outcome.command,
                                  output: CommandProposal.output(sessions.existing(tabID)?.screenLines() ?? [],
                                                                 command: outcome.command)))
    }

    /// The proposal's tab closed before anything ran there.
    func proposalTabClosed(_ tabID: UUID) {
        guard let p = proposedCommands.removeValue(forKey: tabID) else { return }
        ShellIntegration.proposals[tabID] = nil
        proposals.settle(p.id, .closed)
    }

    /// Hides the bar; the tool still learns how the command went.
    func dismissProposal(_ tabID: UUID) { proposedCommands[tabID] = nil }

    private static func short(_ command: String) -> String {
        let first = command.split(separator: " ").prefix(2).joined(separator: " ")
        return first.count > 28 ? String(first.prefix(27)) + "…" : first
    }
}

enum ProposalError: Error {
    case invalid(String), noTab

    var message: String {
        switch self {
        case .invalid(let why): why
        case .noTab: "That Smart Terminal tab isn't open any more."
        }
    }
}
