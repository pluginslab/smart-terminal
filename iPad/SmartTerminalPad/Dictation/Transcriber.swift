import Foundation

enum TranscribeError: LocalizedError {
    case badEndpoint, http(Int, String), badResponse
    var errorDescription: String? {
        switch self {
        case .badEndpoint: "The dictation endpoint in the host's Glossa config is not a URL."
        case .http(let code, let body): "Transcription failed: HTTP \(code) \(body.prefix(120))"
        case .badResponse: "Transcription failed: unexpected response."
        }
    }
}

/// One multipart POST in the OpenAI `/v1/audio/transcriptions` shape. Works against
/// llm-router, Speaches, whisper.cpp's server and OpenAI alike.
struct Transcriber {
    let config: DictationConfig

    func transcribe(wav: Data, prompt: String) async throws -> String {
        guard let url = URL(string: config.endpoint), url.host != nil else { throw TranscribeError.badEndpoint }
        let boundary = "----SmartTerminal-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty { req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", config.model)
        field("response_format", "json")
        field("temperature", "0.0")
        if !config.language.isEmpty { field("language", config.language) }
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw TranscribeError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else { throw TranscribeError.badResponse }
        return text
    }
}
