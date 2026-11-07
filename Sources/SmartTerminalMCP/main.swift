import Darwin
import Foundation

// smart-terminal-mcp: Smart Terminal's MCP server for the Claude Code session in a tab.
//
//   claude mcp add -s user smart-terminal -- /Applications/SmartTerminal.app/Contents/MacOS/smart-terminal-mcp
//
// It speaks MCP over stdio and asks the app, through the local gate every shell in
// a tab is told about (SMART_TERMINAL_GATE, a file only you can read, and
// SMART_TERMINAL_TAB), to act in the tab it runs in. Outside Smart Terminal it offers
// no tools.

let version = "1"

struct Gate {
    let url: String
    let token: String
    let tab: String

    /// The gate of the Smart Terminal this process runs in, or nil.
    static func current(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Gate? {
        guard let file = env["SMART_TERMINAL_GATE"], let data = FileManager.default.contents(atPath: file),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              info["version"] as? Int == 1, let url = info["url"] as? String, let token = info["token"] as? String
        else { return nil }
        if let pid = info["pid"] as? Int32, kill(pid, 0) != 0, errno == ESRCH { return nil } // that app has quit
        // Inside tmux the tab is whichever started the tmux server: ask for the tab in front.
        let tab = env["TMUX"] != nil ? "-" : (env["SMART_TERMINAL_TAB"] ?? "-")
        return Gate(url: url, token: token, tab: tab)
    }

    func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, timeout: Double) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: url + path)!, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
    }
}

// MARK: Tools

let tools: [[String: Any]] = [
    [
        "name": "propose_command",
        "description": """
        Opens a new Smart Terminal tab next to this session, in its group, with `command` typed at the prompt, and waits for the person to press Return. Nothing runs until they do; they can edit the line first. Use it instead of asking the person to type `! <command>`: for commands they have to run themselves (interactive logins like `gcloud auth login`, anything that asks for a password, a 2FA code or sudo, `npm publish`, a long-running dev server they want to watch). Returns the exit status, the command as it actually ran, and the last screen of output. If they haven't run it within wait_seconds you get its id; call command_status to keep waiting. One line only: join steps with && or put them in a script.
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "command": ["type": "string", "description": "One shell command line, as the person would type it."],
                "cwd": ["type": "string", "description": "Folder to run it in. Defaults to this session's current folder."],
                "reason": ["type": "string", "description": "One short sentence shown above the command: why it needs to run and what the person should expect (a browser login, a code prompt)."],
                "wait_seconds": ["type": "number", "description": "How long to wait for it to finish. Default 600, at most 1800."],
            ],
            "required": ["command"],
        ],
    ],
    [
        "name": "command_status",
        "description": "Waits for a command proposed with propose_command and reports it: still waiting, ran (exit status and last output), or the tab was closed without running it.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The id propose_command returned."],
                "wait_seconds": ["type": "number", "description": "How long to wait for it. Default 600, at most 1800."],
            ],
            "required": ["id"],
        ],
    ],
]

func describe(_ r: [String: Any]) -> (String, Bool) {
    let id = r["id"] as? String ?? "?"
    switch r["status"] as? String {
    case "ran":
        let code = r["exitCode"] as? Int ?? -1
        let output = (r["output"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(nothing on screen)"
        return ("The person ran it in a new Smart Terminal tab. Exit status \(code).\n$ \(r["command"] as? String ?? "")\n\nLast output on screen:\n\(output)", false)
    case "pending":
        return ("Typed into a new Smart Terminal tab; the person hasn't run it yet. Command id \(id): call command_status with it to keep waiting.", false)
    case "closed":
        return ("The person closed the tab without running the command.", false)
    case "typed":
        return ("Typed into a new Smart Terminal tab. That tab's shell isn't zsh, so Smart Terminal can't tell when it ran or how it went: ask the person.", false)
    default:
        return (r["error"] as? String ?? "Smart Terminal gave an answer this tool doesn't know.", true)
    }
}

func waitSeconds(_ args: [String: Any]) -> Double { min(max((args["wait_seconds"] as? Double) ?? 600, 0), 1800) }

func callTool(_ name: String, _ args: [String: Any]) async -> (String, Bool) {
    guard let gate = Gate.current() else {
        return ("This session isn't running in a Smart Terminal tab (or that Smart Terminal has quit).", true)
    }
    do {
        switch name {
        case "propose_command":
            let wait = waitSeconds(args)
            var body: [String: Any] = ["tab": gate.tab, "command": args["command"] as? String ?? "", "wait": wait]
            if let cwd = args["cwd"] as? String { body["cwd"] = cwd }
            if let reason = args["reason"] as? String { body["reason"] = reason }
            let (code, r) = try await gate.call("POST", "/v1/commands", body, timeout: wait + 30)
            if code != 200 { return ("Smart Terminal didn't open it: \(r["error"] as? String ?? "HTTP \(code)")", true) }
            return describe(r)
        case "command_status":
            let id = (args["id"] as? String ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(["-"])) ?? ""
            let wait = waitSeconds(args)
            let (code, r) = try await gate.call("GET", "/v1/commands/\(id)?wait=\(Int(wait))", timeout: wait + 30)
            if code != 200 { return (r["error"] as? String ?? "HTTP \(code)", true) }
            return describe(r)
        default:
            return ("No tool named \(name).", true)
        }
    } catch {
        return ("Couldn't reach Smart Terminal: \(error.localizedDescription)", true)
    }
}

// MARK: JSON-RPC over stdio

let out = FileHandle.standardOutput
let writeLock = NSLock()
func send(_ msg: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: msg) else { return }
    data.append(0x0A)
    writeLock.lock(); out.write(data); writeLock.unlock()
}
func reply(_ id: Any, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
func fail(_ id: Any, _ code: Int, _ message: String) { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }

func handle(_ msg: [String: Any]) async {
    guard let method = msg["method"] as? String else { return }
    guard let id = msg["id"] else { return } // a notification: nothing to answer
    let params = msg["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        let inside = Gate.current() != nil
        reply(id, [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "smart-terminal", "version": version],
            "instructions": inside
                ? "This Claude Code session runs in a Smart Terminal tab. When the person has to run a command themselves (a login, a 2FA or password prompt, sudo, publishing), call propose_command instead of asking them to type `! <command>`: it types the command into a new tab beside this one and waits for them to press Return."
                : "Not running in a Smart Terminal tab: no tools.",
        ])
    case "ping":
        reply(id, [:])
    case "tools/list":
        reply(id, ["tools": Gate.current() == nil ? [] : tools])
    case "tools/call":
        let (text, isError) = await callTool(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
        reply(id, ["content": [["type": "text", "text": text]], "isError": isError])
    default:
        fail(id, -32601, "Method not found: \(method)")
    }
}

setvbuf(stdout, nil, _IONBF, 0)
let group = DispatchGroup()
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let data = line.data(using: .utf8),
          let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
    group.enter()
    Task { await handle(msg); group.leave() } // requests run side by side: a long wait never blocks a ping
}
group.wait()
