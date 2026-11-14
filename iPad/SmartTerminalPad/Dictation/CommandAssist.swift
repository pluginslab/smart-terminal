import Foundation

/// Voice commands for a plain shell: what you said, plus where the pane is (host,
/// folder, a listing, recent history, the screen), goes to llm-router once, and the
/// one command it answers with is typed into the terminal without Return. You read
/// it and press return yourself. One round: it gets it or it asks, never a follow-up.
///
/// The endpoint and key come from `~/.config/smart-terminal/assist.json` on the host
/// (a llm-router virtual key scoped to fast/code/transcribe), read over the app's SSH
/// connection like Glossa's config, so nothing is kept on the device.
struct CommandAssist {
    struct Config: Decodable {
        var endpoint: String
        var apiKey: String
        var model: String = "code"

        enum CodingKeys: String, CodingKey { case endpoint, apiKey, model }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            endpoint = try c.decode(String.self, forKey: .endpoint)
            apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        }
    }

    enum Outcome: Equatable {
        case command(String)
        case ask(String)
    }

    enum AssistError: LocalizedError {
        case badEndpoint, http(Int, String), empty
        var errorDescription: String? {
            switch self {
            case .badEndpoint: "The endpoint in ~/.config/smart-terminal/assist.json is not a URL."
            case .http(let code, let body): "Command assist failed: HTTP \(code) \(body.prefix(120))"
            case .empty: "No command came back."
            }
        }
    }

    static let configPath = "~/.config/smart-terminal/assist.json"

    /// What the host tells about the pane's folder, in one round trip (with the config).
    static func contextScript(path: String) -> String {
        let p = path.isEmpty ? "~" : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        cd \(p) 2>/dev/null || cd
        echo "host: $(hostname) ($(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME"))"
        echo "user: $(whoami)   shell: $SHELL"
        echo "cwd: $(pwd)"
        b=$(git branch --show-current 2>/dev/null) && [ -n "$b" ] && echo "git branch: $b"
        echo "ls -Ap (first 60):"; ls -Ap 2>/dev/null | head -60
        d=$(docker ps --format '{{.Names}}' 2>/dev/null | tr '\\n' ' ') && [ -n "$d" ] && echo "docker containers: $d"
        echo "recent shell history:"; tail -n 15 ~/.zsh_history 2>/dev/null | sed 's/^: [0-9]*:[0-9]*;//'
        """
    }

    private static let system = """
    You turn a spoken request into ONE shell command, to be typed into the terminal described \
    below. The user reads it and presses return; you never run anything.
    Reply with exactly one line and nothing else:
    CMD: <the command>
    or, when it can't be a sensible command (unclear, not a terminal task, or you'd have to guess \
    a path or name you can't see in the context):
    ASK: <one short question>
    Rules: one line, chain steps with && if needed. Write for the shell named in the context.     In zsh: never put ! in a pattern or in double quotes (history expansion breaks it), and a     pattern that matches nothing is an error, so for hidden files use zsh's *(D) or *(ND)     instead of bash idioms like .[!.]* (sizes of everything here: du -sh -- *(D) | sort -hr).     Keep commands as light as the request: the entries here, not the whole tree below. You're already typing into the right terminal: \
    never wrap the command in ssh, tmux send-keys or similar. Prefer names you can see in the \
    context (folders in the listing, docker containers) over guessing. "start claude" means \
    running `claude`. Never use echo or printf to talk to the user: if it isn't a terminal task,     ASK. No markdown, no explanation, no backticks.
    """

    let config: Config

    /// Streams the answer, calling `progress` with the text so far.
    func compose(request: String, context: String, screen: String?,
                 progress: @escaping @MainActor (String) -> Void) async throws -> Outcome {
        guard let url = URL(string: config.endpoint), url.host != nil else { throw AssistError.badEndpoint }
        var user = "Terminal:\n\(context)"
        if let screen, !screen.isEmpty { user += "\n\nLast lines on screen:\n\(screen)" }
        user += "\n\nRequest: \(request)"
        let body: [String: Any] = [
            "model": config.model, "stream": true, "max_tokens": 400, "temperature": 0,
            "messages": [["role": "system", "content": Self.system], ["role": "user", "content": user]],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty { req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var text = ""
            for try await line in bytes.lines { text += line; if text.count > 300 { break } }
            throw AssistError.http(http.statusCode, text)
        }
        var reasoning = "", content = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: "), !line.contains("[DONE]"),
                  let data = line.dropFirst(6).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let delta = (json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { continue }
            if let r = (delta["reasoning_content"] ?? delta["reasoning"]) as? String { reasoning += r }
            if let c = delta["content"] as? String { content += c }
            let shown = content.isEmpty ? reasoning : content
            await progress(shown.replacingOccurrences(of: "\n", with: " "))
        }
        return try Self.parse(content)
    }

    static func parse(_ raw: String) throws -> Outcome {
        let line = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        func strip(_ s: Substring) -> String {
            s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        }
        if line.hasPrefix("CMD:") { let c = strip(line.dropFirst(4)); if !c.isEmpty { return .command(c) } }
        if line.hasPrefix("ASK:") { let q = strip(line.dropFirst(4)); if !q.isEmpty { return .ask(q) } }
        if line.isEmpty { throw AssistError.empty }
        return .ask(line)   // not in the format: show it rather than type it
    }

    /// Commands worth a second look before return: deleting, privileges, disks, force pushes.
    static func warning(for command: String) -> String? {
        let checks: [(String, String)] = [
            (#"\brm\s+(-[a-zA-Z]*[rf]|--recursive|--force)"#, "deletes files"),
            (#"\bsudo\b"#, "runs as root"),
            (#"\b(dd|mkfs(\.\w+)?|fdisk|parted|wipefs)\b"#, "writes to a disk"),
            (#"\bgit\s+push\b.*(-f\b|--force)"#, "force-pushes"),
            (#"\bgit\s+(reset\s+--hard|clean\s+-[a-zA-Z]*f)"#, "throws away changes"),
            (#"\b(shutdown|reboot|halt|poweroff)\b"#, "stops the machine"),
            (#"\b(kill|pkill|killall)\b"#, "stops processes"),
            (#"\bchmod\s+(-R\s+)?[0-7]*777\b|\bchown\s+-R\b"#, "changes permissions widely"),
            (#">\s*/(etc|boot|dev)/"#, "overwrites a system file"),
        ]
        for (pattern, what) in checks where command.range(of: pattern, options: .regularExpression) != nil {
            return "Careful: this \(what). Check it before return."
        }
        return nil
    }
}
