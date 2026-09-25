// A stand-in for `claude`, for recording the README demo without real sessions.
//
// It writes what Claude Code writes, so Smart Terminal treats it as a real session:
// the session file ($CLAUDE_CONFIG_DIR/sessions/<pid>.json), a transcript with token
// usage and an AI title, the ◐/✳ terminal title, and three subagents with their own
// transcripts and .meta.json files. Everything is invented; nothing is sent anywhere.
//
// scripts/record-demo.sh compiles it to .build/demo-bin/claude, which demo/home/.zshrc
// puts first on PATH. A real executable named `claude` keeps the window title honest:
// no interpreter name, no script path.
import Foundation

guard let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] else {
    FileHandle.standardError.write("CLAUDE_CONFIG_DIR is not set (demo only)\n".data(using: .utf8)!)
    exit(1)
}
setvbuf(stdout, nil, _IONBF, 0)

let pid = getpid()
let cwd = FileManager.default.currentDirectoryPath
let sid = UUID().uuidString.lowercased()
let title = "Fix flaky checkout retries"
let prompt = "the checkout test fails every few runs. find out why, fix it, and check the payment webhooks while you're at it"
let started = Int(Date().timeIntervalSince1970 * 1000)

let encoded = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
let projects = "\(config)/projects/\(encoded)"
let transcript = "\(projects)/\(sid).jsonl"
let subagentsDir = "\(projects)/\(sid)/subagents"
let sessionFile = "\(config)/sessions/\(pid).json"
try? FileManager.default.createDirectory(atPath: subagentsDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: "\(config)/sessions", withIntermediateDirectories: true)

let orange = "\u{1b}[38;2;215;119;87m", dim = "\u{1b}[2m", bold = "\u{1b}[1m", green = "\u{1b}[32m", reset = "\u{1b}[0m"
let spinner: [Character] = ["◐", "◓", "◑", "◒"]

func now() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
}

func append(_ path: String, _ obj: [String: Any]) {
    var data = try! JSONSerialization.data(withJSONObject: obj)
    data.append(0x0A)
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile(); h.write(data); h.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}

func session(_ status: String) {
    let obj: [String: Any] = ["pid": pid, "sessionId": sid, "cwd": cwd, "status": status, "startedAt": started,
                              "statusUpdatedAt": Int(Date().timeIntervalSince1970 * 1000), "kind": "interactive"]
    try? JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: sessionFile))
}

func setTitle(_ glyph: Character) { print("\u{1b}]0;\(glyph) \(title)\u{7}", terminator: "") }
func say(_ text: String = "") { print(text + "\r") }
func pause(_ s: Double) { usleep(useconds_t(s * 1_000_000)) }
func id(_ prefix: String, _ n: Int) -> String { prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(n) }

var context = 236_000

func reply(_ content: [[String: Any]], add: Int = 0, output: Int = 600) {
    context += add
    append(transcript, ["type": "assistant", "timestamp": now(), "sessionId": sid, "isSidechain": false,
                        "message": ["id": id("msg_", 20), "model": "claude-opus-5-5", "content": content,
                                    "usage": ["input_tokens": 4, "cache_read_input_tokens": context - 2000,
                                              "cache_creation_input_tokens": 1996, "output_tokens": output]]])
}

func toolResult(_ toolID: String, _ text: String, _ result: [String: Any]? = nil) {
    append(transcript, ["type": "user", "timestamp": now(), "sessionId": sid, "isSidechain": false,
                        "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": toolID, "content": text]]],
                        "toolUseResult": result ?? ["stdout": text]])
}

final class Subagent {
    let description: String, kind: String, background: Bool
    var steps: [(tool: String, arg: String, output: String)]
    let toolID = id("toolu_", 24), agentID = id("", 17)
    var path: String { "\(subagentsDir)/agent-\(agentID).jsonl" }
    let started = Date()
    var tools = 0
    var done = false

    init(_ description: String, _ kind: String, background: Bool = false, _ steps: [(String, String, String)]) {
        self.description = description; self.kind = kind; self.background = background
        self.steps = steps.map { (tool: $0.0, arg: $0.1, output: $0.2) }
    }

    func launch() {
        let meta: [String: Any] = ["agentType": kind, "description": description, "toolUseId": toolID,
                                   "spawnDepth": 1, "requestShape": background ? "background" : "foreground"]
        try? JSONSerialization.data(withJSONObject: meta).write(to: URL(fileURLWithPath: "\(subagentsDir)/agent-\(agentID).meta.json"))
        append(path, ["type": "user", "isSidechain": true, "timestamp": now(),
                      "message": ["role": "user", "content": "\(description). Report what you find, briefly."]])
    }

    /// Adds the next tool call and its result to the subagent's own transcript.
    func step() {
        guard !steps.isEmpty else { return }
        let s = steps.removeFirst()
        let tid = id("toolu_", 24)
        let key = ["Bash": "command", "Read": "file_path", "Grep": "pattern"][s.tool]!
        append(path, ["type": "assistant", "isSidechain": true, "timestamp": now(),
                      "message": ["model": "claude-haiku-4-5-20251001",
                                  "content": [["type": "tool_use", "id": tid, "name": s.tool, "input": [key: s.arg]]]]])
        append(path, ["type": "user", "isSidechain": true, "timestamp": now(),
                      "message": ["content": [["type": "tool_result", "tool_use_id": tid, "content": s.output]]]])
        tools += 1
    }

    func finish(_ summary: String) {
        done = true
        append(path, ["type": "assistant", "isSidechain": true, "timestamp": now(),
                      "message": ["model": "claude-haiku-4-5-20251001", "content": [["type": "text", "text": summary]]]])
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let tokens = 38_000 + tools * 2_400
        if background {
            let note = """
                <task-notification>
                <task-id>\(agentID)</task-id>
                <tool-use-id>\(toolID)</tool-use-id>
                <status>completed</status>
                <summary>Agent "\(description)" finished</summary>
                <usage><subagent_tokens>\(tokens)</subagent_tokens><tool_uses>\(tools)</tool_uses><duration_ms>\(ms)</duration_ms></usage>
                <result>\(summary)</result>
                </task-notification>
                """
            append(transcript, ["type": "user", "timestamp": now(), "sessionId": sid, "origin": ["kind": "task-notification"],
                                "message": ["role": "user", "content": note]])
        } else {
            toolResult(toolID, summary, ["status": "completed", "agentId": agentID, "totalDurationMs": ms,
                                         "totalTokens": tokens, "totalToolUseCount": tools])
        }
        say("  \(green)✓\(reset) \(description) \(dim)· \(tools) tools\(reset)")
    }
}

for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig) { _ in
        unlink(sessionFile)
        print("\u{1b}]0;\u{7}", terminator: "")
        exit(0)
    }
}

/// Animates the title and a status line, like Claude Code's spinner.
func spin(_ seconds: Double, _ label: String, since t0: Date) {
    let end = Date().addingTimeInterval(seconds)
    var i = 0
    while Date() < end {
        setTitle(spinner[i % 4])
        print("\r\(orange)✻\(reset) \(label)… \(dim)(\(Int(Date().timeIntervalSince(t0)))s · esc to interrupt)\(reset)\u{1b}[K", terminator: "")
        pause(0.25)
        i += 1
    }
    print("\r\u{1b}[K", terminator: "")
}

// MARK: - The scene

say("\(orange)✻\(reset) \(bold)Claude Code\(reset) \(dim)(demo)\(reset)")
say("\(dim)  Opus 5.5 · \(cwd.replacingOccurrences(of: ProcessInfo.processInfo.environment["HOME"] ?? "~", with: "~"))\(reset)")
say()
session("idle")
setTitle("✳")
pause(1.2)

print("\(dim)>\(reset) ", terminator: "")
for c in prompt { print(String(c), terminator: ""); pause(0.018) }
say(); say()
let t0 = Date()
append(transcript, ["type": "user", "timestamp": now(), "sessionId": sid, "isSidechain": false,
                    "message": ["role": "user", "content": prompt]])
append(transcript, ["type": "ai-title", "aiTitle": title, "sessionId": sid])
session("busy")
spin(1.5, "Thinking", since: t0)

reply([["type": "text", "text": "I'll look at the retry path and the webhooks in parallel."]], add: 4_000)
say("⏺ I'll look at the retry path and the webhooks in parallel.")
say()

let agents = [
    Subagent("Find where checkout retries", "Explore", [
        ("Grep", "retryPayment", "src/checkout/retry.ts:14\nsrc/checkout/retry.ts:52\ntest/checkout.spec.ts:88"),
        ("Read", "~/code/acme-api/src/checkout/retry.ts", "export async function retryPayment(order) {\n  for (let i = 0; i < 3; i++) {\n    await sleep(100)\n  …"),
        ("Bash", "npm test -- checkout --repeat 20", "18 passed, 2 failed\n  ✗ retries a declined card (timeout after 250ms)"),
    ]),
    Subagent("Audit webhook signature checks", "general-purpose", background: true, [
        ("Grep", "verifySignature", "src/webhooks/stripe.ts:31\nsrc/webhooks/paypal.ts:19"),
        ("Read", "~/code/acme-api/src/webhooks/paypal.ts", "// TODO: verify signature\nexport function handle(event) {\n  …"),
        ("Bash", "git log --oneline -3 -- src/webhooks", "a41c2e9 paypal: accept sandbox events\n7be0d13 stripe: verify signatures\n19f00aa webhooks: add router"),
    ]),
    Subagent("Map payment test fixtures", "Explore", [
        ("Bash", "ls test/fixtures/payments", "declined-card.json\nexpired-card.json\nok-visa.json"),
        ("Read", "~/code/acme-api/test/fixtures/payments/declined-card.json", "{ \"status\": \"declined\", \"retryAfterMs\": 300 }"),
    ]),
]
reply(agents.map { a in
    var input: [String: Any] = ["description": a.description, "subagent_type": a.kind, "prompt": a.description]
    if a.background { input["run_in_background"] = true }
    return ["type": "tool_use", "id": a.toolID, "name": "Agent", "input": input]
}, add: 6_000, output: 900)
for a in agents {
    a.launch()
    say("⏺ \(bold)Agent\(reset)(\(a.description))\(dim)\(a.background ? "  · background" : "")\(reset)")
    if a.background { toolResult(a.toolID, "Async agent launched", ["status": "async_launched", "agentId": a.agentID]) }
}
say()

// The subagents work: one step every 1.4 s, round-robin, and finish in turn.
let summaries = [
    "The retry waits 3×100 ms but the declined-card fixture asks for 300 ms, so the test's 250 ms timeout races it.",
    "Stripe verifies signatures. PayPal doesn't: there's a TODO in src/webhooks/paypal.ts.",
    "declined-card.json sets retryAfterMs: 300; nothing else depends on it.",
]
for (n, i) in [0, 1, 2, 0, 2, 1, 0, 1].enumerated() {
    spin(1.4, n < 4 ? "Waiting for 3 agents" : "Waiting for agents", since: t0)
    agents[i].step()
    if agents[i].steps.isEmpty, !agents[i].done { agents[i].finish(summaries[i]) }
}
for (i, a) in agents.enumerated() where !a.done { a.finish(summaries[i]) }

say()
spin(1.6, "Editing", since: t0)
reply([["type": "tool_use", "id": "toolu_edit1", "name": "Edit", "input": ["file_path": cwd + "/src/checkout/retry.ts"]]], add: 58_000)
toolResult("toolu_edit1", "Updated src/checkout/retry.ts")
say("⏺ \(bold)Update\(reset)(src/checkout/retry.ts)")
say("  \(dim)⎿\(reset)  Honour \(bold)retryAfterMs\(reset) from the gateway instead of a fixed 100 ms")
say()
spin(1.4, "Running tests", since: t0)
reply([["type": "text", "text": "Fixed. checkout passes 50/50 runs now. PayPal webhooks don't verify signatures: want me to add that next?"]],
      add: 8_000, output: 1_400)
append(transcript, ["type": "system", "subtype": "turn_duration", "durationMs": Int(Date().timeIntervalSince(t0) * 1000),
                    "timestamp": now(), "isSidechain": false])
say("⏺ Fixed: checkout passes \(green)50/50\(reset) runs now.")
say("  PayPal webhooks don't verify signatures: want me to add that next?")
say()
session("idle")
setTitle("✳")
print("\(dim)>\(reset) ", terminator: "")

// Idle until the tab closes or ^C.
while true { pause(1) }
