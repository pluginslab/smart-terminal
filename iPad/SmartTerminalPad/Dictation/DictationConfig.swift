import Foundation

/// Glossa's `~/.config/glossa/config.json`, read from the host over SSH. The same
/// file the Mac app uses, so one server, one key and one glossary serve both.
/// Only the keys dictation needs are decoded; the rest of the file is ignored.
struct DictationConfig: Decodable {
    /// Any OpenAI-style `/v1/audio/transcriptions` endpoint, llm-router's `transcribe` in practice.
    var endpoint = ""
    var apiKey = ""
    var model = "whisper-1"
    /// Whisper language code; empty means auto-detect (slower).
    var language = "en"
    /// Send the text before the cursor as part of the prompt.
    var useContext = true
    var contextChars = 300
    /// Recordings shorter than this are dropped as accidental taps.
    var minSeconds = 0.4

    enum CodingKeys: String, CodingKey { case endpoint, apiKey, model, language, useContext, contextChars, minSeconds }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? endpoint
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? apiKey
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? language
        useContext = try c.decodeIfPresent(Bool.self, forKey: .useContext) ?? useContext
        contextChars = try c.decodeIfPresent(Int.self, forKey: .contextChars) ?? contextChars
        minSeconds = try c.decodeIfPresent(Double.self, forKey: .minSeconds) ?? minSeconds
    }

    static let path = "~/.config/glossa/config.json"
    static let glossaryPath = "~/.config/glossa/glossary.txt"

    /// Glossary lines, one term each; `#` lines and blanks skipped (Glossa's format).
    static func glossary(from text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Whisper's prompt: vocabulary first, the text before the cursor last, so the
    /// context is what gets cut when the prompt is longer than the model keeps.
    static func prompt(glossary: [String], before: String?) -> String {
        var parts: [String] = []
        if !glossary.isEmpty { parts.append("Vocabulary: " + glossary.joined(separator: ", ") + ".") }
        if let before = before?.trimmingCharacters(in: .whitespacesAndNewlines), !before.isEmpty {
            parts.append(before)
        }
        return parts.joined(separator: "\n")
    }
}
