import Darwin
import Foundation

/// The app's private line to Chromium's DevTools protocol, instead of a TCP port
/// any process on the Mac could connect to.
///
/// Chromium started with `--remote-debugging-pipe` reads commands from file
/// descriptor 3 and writes replies and events to 4, each message JSON ended by a NUL
/// byte. Those two numbers are fixed, so `reserve()` claims them at launch, before
/// anything else can take them; both are close-on-exec, so no shell or tool started
/// from a tab inherits them.
enum DevToolsPipe {
    /// Our ends: write commands here, read messages there. -1 until reserved.
    nonisolated(unsafe) private(set) static var commandFD: Int32 = -1
    nonisolated(unsafe) private(set) static var messageFD: Int32 = -1

    static var isReserved: Bool { commandFD >= 0 }

    /// Run first thing in `main`. False (and Chromium falls back to nothing) if
    /// descriptors 3 or 4 are already taken.
    @discardableResult
    static func reserve() -> Bool {
        guard !isReserved, fcntl(3, F_GETFD) == -1, fcntl(4, F_GETFD) == -1 else { return false }
        var toChromium: [Int32] = [-1, -1], fromChromium: [Int32] = [-1, -1]
        guard pipe(&toChromium) == 0 else { return false }
        guard pipe(&fromChromium) == 0 else { toChromium.forEach { close($0) }; return false }
        // pipe() hands out the lowest free numbers, likely 3 and 4 themselves: lift all
        // four out of the way first, then place Chromium's two ends.
        let high = (toChromium + fromChromium).map { fd -> Int32 in
            let moved = fcntl(fd, F_DUPFD_CLOEXEC, 64)
            close(fd)
            return moved
        }
        guard !high.contains(-1) else { high.forEach { if $0 >= 0 { close($0) } }; return false }
        let (chromiumReads, ourWrite, ourRead, chromiumWrites) = (high[0], high[1], high[2], high[3])
        guard dup2(chromiumReads, 3) == 3, dup2(chromiumWrites, 4) == 4 else {
            high.forEach { close($0) }
            return false
        }
        close(chromiumReads)
        close(chromiumWrites)
        _ = fcntl(3, F_SETFD, FD_CLOEXEC)
        _ = fcntl(4, F_SETFD, FD_CLOEXEC)
        commandFD = ourWrite
        messageFD = ourRead
        // A write to a pipe whose reader died must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        return true
    }
}

/// Sends DevTools commands over the pipe and routes what comes back: replies to the
/// callback of the command they answer, everything else to `onMessage`.
@MainActor
final class DevToolsConnection {
    static let shared = DevToolsConnection()

    /// Messages that aren't replies to `send` (events, and replies to raw forwards).
    var onMessage: ((Data) -> Void)?
    private var pending: [Int: (([String: Any]) -> Void)] = [:]
    private var nextID = 1_000_000_000 // far above any id a client of the gate uses
    private var buffer = Data()
    private var source: DispatchSourceRead?
    private let writeQueue = DispatchQueue(label: "devtools.pipe.write")

    private init() {}

    /// Starts reading. Call once Chromium runs.
    func open() {
        guard source == nil, DevToolsPipe.isReserved else { return }
        let fd = DevToolsPipe.messageFD
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return }
            MainActor.assumeIsolated { self?.received(Data(chunk[0..<n])) }
        }
        src.resume()
        source = src
    }

    private func received(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0) {
            let message = buffer[buffer.startIndex..<end]
            buffer.removeSubrange(buffer.startIndex...end)
            dispatch(Data(message))
        }
    }

    private func dispatch(_ message: Data) {
        if let obj = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
           let id = obj["id"] as? Int, let reply = pending.removeValue(forKey: id) {
            reply(obj)
        } else {
            onMessage?(message)
        }
    }

    /// Sends a command of the app's own; `reply` gets the whole response object.
    func send(method: String, params: [String: Any] = [:], sessionId: String? = nil,
              reply: (([String: Any]) -> Void)? = nil) {
        let id = nextID
        nextID += 1
        var obj: [String: Any] = ["id": id, "method": method, "params": params]
        if let sessionId { obj["sessionId"] = sessionId }
        if let reply { pending[id] = reply }
        if let data = try? JSONSerialization.data(withJSONObject: obj) { write(data) }
    }

    /// Sends a message as is (the gate forwarding a client's command).
    func write(_ message: Data) {
        var framed = message
        framed.append(0)
        let fd = DevToolsPipe.commandFD
        writeQueue.async {
            framed.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { if errno == EINTR { continue }; return }
                    offset += n
                }
            }
        }
    }
}
