import Foundation
import Observation
import UIKit
import os

/// Dictation into the session in front: record on the iPad, send the audio to the
/// Whisper server named in the host's Glossa config with the glossary and the text
/// before the cursor as the prompt, and type the result into the tmux pane.
///
/// Tap to start, tap to stop. No settings on the device: `~/.config/glossa/config.json`
/// and `glossary.txt` on the host are read over the SSH connection the app already has,
/// so the Mac's Glossa and this app share one server, one key and one glossary.
@MainActor @Observable
final class Dictation {
    enum State: Equatable {
        case idle, starting, recording, transcribing
        /// Command mode: the request went to the model; the text so far.
        case composing(String)
        /// Command mode: what the model asked back, or a warning about the typed command.
        case notice(String)
        case failed(String)
    }

    private(set) var state: State = .idle { didSet { Self.log.info("state \(String(describing: self.state), privacy: .public)") } }
    private static let log = Logger(subsystem: "com.pluginslab.smartterminal.pad", category: "dictation")
    private let recorder = Recorder()
    private var config: DictationConfig?
    private var glossary: [String] = []
    private var configTask: Task<Void, Never>?
    /// Set for a plain shell: what was said becomes a command (see `CommandAssist`).
    private var assist: CommandAssist.Config?
    private var assistContext = ""
    private var commandMode = false
    private var clearTask: Task<Void, Never>?

    /// Recent loudness (0...1, newest last) for the key bar's waveform; cleared per recording.
    private(set) var levels: [Float] = []
    private static let maxLevels = 400

    var isActive: Bool {
        switch state {
        case .recording, .transcribing, .starting, .composing: true
        default: false
        }
    }

    /// `commandIn`: the pane's folder when it runs a plain shell (no Claude): then what
    /// you say becomes a command typed for you, not the words themselves.
    /// `contextHost`: where the pane runs, when that isn't `host` (iSH+'s Linux): the
    /// configs still come from `host`, the folder's context from there.
    func toggle(host: Host, contextHost: Host? = nil, pane: TerminalPane, commandIn folder: String? = nil) {
        switch state {
        case .recording: stop(into: pane)
        case .starting, .transcribing, .composing: break
        case .idle, .failed, .notice: start(host: host, contextHost: contextHost ?? host, commandIn: folder)
        }
    }

    private func start(host: Host, contextHost: Host, commandIn folder: String?) {
        clearTask?.cancel()
        state = .starting
        commandMode = folder != nil
        // Fetch the config and glossary while the user talks: two files, one round trip
        // (plus the assist's config and the folder's context in command mode).
        var script = "cat \(DictationConfig.path) 2>/dev/null; echo '@@GLOSSA@@'; cat \(DictationConfig.glossaryPath) 2>/dev/null"
        let local = contextHost !== host
        if let folder {
            script += "; echo '@@ASSIST@@'; cat \(CommandAssist.configPath) 2>/dev/null; echo '@@CONTEXT@@'"
            if !local { script += "; " + CommandAssist.contextScript(path: folder) }
        }
        configTask = Task { [weak self] in
            async let context: String? = local && folder != nil
                ? contextHost.run("sh -c " + Host.quote(CommandAssist.contextScript(path: folder!))) : nil
            var out = await host.run("sh -c " + Host.quote(script))
            if let extra = await context { out = (out ?? "") + "\n" + extra }
            guard let self else { return }
            var rest = out ?? ""
            var assistPart = "", contextPart = ""
            if let r = rest.range(of: "@@ASSIST@@\n") {
                let tail = String(rest[r.upperBound...]); rest = String(rest[..<r.lowerBound])
                let pieces = tail.components(separatedBy: "@@CONTEXT@@\n")
                assistPart = pieces.first ?? ""; contextPart = pieces.count > 1 ? pieces[1] : ""
            }
            assist = assistPart.data(using: .utf8).flatMap { try? JSONDecoder().decode(CommandAssist.Config.self, from: $0) }
            assistContext = contextPart
            let parts = rest.components(separatedBy: "@@GLOSSA@@\n")
            if let data = parts.first?.data(using: .utf8), let c = try? JSONDecoder().decode(DictationConfig.self, from: data) {
                config = c
            }
            glossary = parts.count > 1 ? DictationConfig.glossary(from: parts[1]) : []
            Self.log.info("host config: \(self.config == nil ? "missing" : "ok", privacy: .public), glossary \(self.glossary.count) terms")
        }
        levels = []
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in
                guard let self else { return }
                self.levels.append(level)
                if self.levels.count > Self.maxLevels { self.levels.removeFirst(self.levels.count - Self.maxLevels) }
            }
        }
        Task {
            do {
                try await recorder.start()
                state = .recording
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } catch {
                fail(Host.describe(error))
            }
        }
    }

    private func stop(into pane: TerminalPane) {
        let (wav, seconds) = recorder.stop()
        Self.log.info("recorded \(seconds, format: .fixed(precision: 1)) s, \(wav.count) bytes")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let before = pane.textBeforeCursor(maxChars: config?.contextChars ?? 300)
        let screen = commandMode ? pane.screenText(lines: 30) : nil
        state = .transcribing
        Task {
            await configTask?.value
            guard let config, !config.endpoint.isEmpty else {
                fail("No dictation config on the host. Put Glossa's config.json at ~/.config/glossa/ there (endpoint, apiKey, model).")
                return
            }
            guard seconds >= config.minSeconds else { state = .idle; return }
            // In command mode the shell prompt isn't dictated text: only the glossary helps.
            let prompt = DictationConfig.prompt(glossary: glossary, before: config.useContext && !commandMode ? before : nil)
            do {
                let started = Date()
                let raw = try await Transcriber(config: config).transcribe(wav: wav, prompt: prompt)
                Self.log.info("transcribed in \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(raw, privacy: .public)")
                if commandMode {
                    await command(from: raw, screen: screen, into: pane)
                } else {
                    insert(raw, before: before, into: pane)
                    state = .idle
                }
            } catch {
                fail(Host.describe(error))
            }
        }
    }

    private func insert(_ raw: String, before: String?, into pane: TerminalPane) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty else { return }
        // Whisper's non-speech markers: [BLANK_AUDIO], (silence), [Music] …
        if (text.hasPrefix("[") && text.hasSuffix("]")) || (text.hasPrefix("(") && text.hasSuffix(")")) { return }
        if let last = before?.last, !last.isWhitespace, !"([{\"'“‘".contains(last) {
            text = " " + text
        }
        pane.write(text)
    }

    /// One round: the request and the pane's context to the model, its one command
    /// typed without Return, or its question shown in the key bar.
    private func command(from raw: String, screen: String?, into pane: TerminalPane) async {
        let request = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !(request.hasPrefix("[") && request.hasSuffix("]")) else { state = .idle; return }
        guard let assist else {
            fail("No command assist config on the host: \(CommandAssist.configPath) (endpoint, apiKey, model).")
            return
        }
        state = .composing("“\(request)”")
        do {
            let started = Date()
            let outcome = try await CommandAssist(config: assist).compose(
                request: request, context: assistContext, screen: screen) { [weak self] text in
                    guard let self, case .composing = self.state else { return }
                    self.state = .composing(text.isEmpty ? "“\(request)”" : text)
                }
            Self.log.info("assist in \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(String(describing: outcome), privacy: .public)")
            switch outcome {
            case .command(let c):
                pane.write(c)
                if let warning = CommandAssist.warning(for: c) { notice(warning) } else { state = .idle }
            case .ask(let q):
                notice(q)
            }
        } catch {
            fail(Host.describe(error))
        }
    }

    /// Shown in the key bar for a while, then gone.
    private func notice(_ message: String) {
        state = .notice(message)
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if case .notice = self?.state { self?.state = .idle }
        }
    }

    private func fail(_ message: String) {
        Self.log.error("failed: \(message, privacy: .public)")
        state = .failed(message)
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if case .failed = self?.state { self?.state = .idle }
        }
    }
}
