import AVFoundation

enum RecorderError: LocalizedError {
    case denied, noInput
    var errorDescription: String? {
        switch self {
        case .denied: "Microphone access is off for Smart Terminal. Turn it on in Settings → Privacy → Microphone."
        case .noInput: "No microphone input."
        }
    }
}

/// Captures the microphone and resamples to 16 kHz mono Int16 PCM, which is what
/// Whisper wants. Same shape as Glossa's recorder on the Mac, plus the audio session
/// iOS needs around it.
final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var pcm = Data()
    private let lock = NSLock()
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    private(set) var isRecording = false
    /// Loudness, 0...1, about 20 times a second while recording (on the audio thread).
    var onLevel: ((Float) -> Void)?
    /// Samples since the last level, and their sum of squares.
    private var levelCount = 0
    private var levelSum: Double = 0

    func start() async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw RecorderError.denied }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        reset()
        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else { throw RecorderError.noInput }
        converter = AVAudioConverter(from: hw, to: target)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: hw) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops and returns a complete WAV file, plus its duration in seconds.
    func stop() -> (wav: Data, seconds: Double) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        lock.lock(); let samples = pcm; lock.unlock()
        let seconds = Double(samples.count) / 2.0 / 16_000.0
        return (Recorder.wav(pcm16: samples), seconds)
    }

    private func reset() { lock.lock(); pcm = Data(); lock.unlock() }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var delivered = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if delivered { status.pointee = .noDataNow; return nil }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        meter(ch[0], count: Int(out.frameLength))
        let bytes = Data(bytes: UnsafeRawPointer(ch[0]), count: Int(out.frameLength) * 2)
        lock.lock(); pcm.append(bytes); lock.unlock()
    }

    /// RMS over 50 ms slices (800 samples at 16 kHz), mapped from -50…0 dBFS to 0…1.
    private func meter(_ samples: UnsafePointer<Int16>, count: Int) {
        for i in 0..<count {
            let v = Double(samples[i]) / 32768
            levelSum += v * v
            levelCount += 1
            if levelCount == 800 {
                let rms = (levelSum / 800).squareRoot()
                let db = 20 * log10(max(rms, 1e-6))
                onLevel?(Float(min(1, max(0, (db + 50) / 50))))
                levelCount = 0
                levelSum = 0
            }
        }
    }

    static func wav(pcm16: Data) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let sampleRate: UInt32 = 16_000, channels: UInt16 = 1, bits: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bits / 8)
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm16.count))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(channels); u32(sampleRate); u32(byteRate)
        u16(channels * bits / 8); u16(bits)
        d.append("data".data(using: .ascii)!); u32(UInt32(pcm16.count))
        d.append(pcm16)
        return d
    }
}
