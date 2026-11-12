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
        case failed(String)
    }

    private(set) var state: State = .idle { didSet { Self.log.info("state \(String(describing: self.state), privacy: .public)") } }
    private static let log = Logger(subsystem: "com.pluginslab.smartterminal.pad", category: "dictation")
    private let recorder = Recorder()
    private var config: DictationConfig?
    private var glossary: [String] = []
    private var configTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?

    var isActive: Bool { state == .recording || state == .transcribing || state == .starting }

    func toggle(host: Host, pane: TerminalPane) {
        switch state {
        case .recording: stop(into: pane)
        case .starting, .transcribing: break
        case .idle, .failed: start(host: host)
        }
    }

    private func start(host: Host) {
        clearTask?.cancel()
        state = .starting
        // Fetch the config and glossary while the user talks: two files, one round trip.
        configTask = Task { [weak self] in
            let out = await host.run("cat \(DictationConfig.path) 2>/dev/null; echo '@@GLOSSA@@'; cat \(DictationConfig.glossaryPath) 2>/dev/null")
            guard let self else { return }
            let parts = (out ?? "").components(separatedBy: "@@GLOSSA@@\n")
            if let data = parts.first?.data(using: .utf8), let c = try? JSONDecoder().decode(DictationConfig.self, from: data) {
                config = c
            }
            glossary = parts.count > 1 ? DictationConfig.glossary(from: parts[1]) : []
            Self.log.info("host config: \(self.config == nil ? "missing" : "ok", privacy: .public), glossary \(self.glossary.count) terms")
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
        state = .transcribing
        Task {
            await configTask?.value
            guard let config, !config.endpoint.isEmpty else {
                fail("No dictation config on the host. Put Glossa's config.json at ~/.config/glossa/ there (endpoint, apiKey, model).")
                return
            }
            guard seconds >= config.minSeconds else { state = .idle; return }
            let prompt = DictationConfig.prompt(glossary: glossary, before: config.useContext ? before : nil)
            do {
                let started = Date()
                let raw = try await Transcriber(config: config).transcribe(wav: wav, prompt: prompt)
                Self.log.info("transcribed in \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(raw, privacy: .public)")
                insert(raw, before: before, into: pane)
                state = .idle
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
