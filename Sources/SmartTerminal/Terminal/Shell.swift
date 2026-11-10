import Darwin
import Foundation

/// Runs helper tools (tmux, ps, git). Not tied to the main actor, so they can be asked
/// from a background queue while polling.
///
/// Spawns with `posix_spawn` and reaps with `waitpid`, not `Process`: its
/// `waitUntilExit` waits on a run loop, and on Swift's task threads it could wait
/// forever for a child that had long exited. Over a day, every tab's tmux probe and
/// git status ended up parked that way, so tabs stopped learning their tmux session.
enum Shell {
    /// For the blocking work: never Swift's cooperative pool, which a stuck call would starve.
    static let queue = DispatchQueue(label: "smartterminal.shell", qos: .utility, attributes: .concurrent)

    /// stdout of a successful run, nil if it couldn't start, exited non-zero or took
    /// longer than `timeout` (it is killed then).
    @discardableResult
    static func run(_ path: String, _ args: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 10) -> String? {
        var out: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { return nil }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&actions, out[0])
        posix_spawn_file_actions_addclose(&actions, out[1])

        let argv = ([path] + args).map { strdup($0) } + [nil]
        let env = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, nil, argv, env)
        close(out[1])
        guard spawned == 0 else { close(out[0]); return nil }

        let killer = DispatchWorkItem { kill(pid, SIGKILL) }
        queue.asyncAfter(deadline: .now() + timeout, execute: killer)
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(out[0], &buf, buf.count)
            if n > 0 { data.append(buf, count: n); continue }
            if n < 0, errno == EINTR { continue }
            break
        }
        close(out[0])
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0, errno == EINTR {}
        killer.cancel()
        let exited = (status & 0x7f) == 0
        guard exited, (status >> 8) & 0xff == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// GUI apps get a minimal PATH; look in the usual places.
    static func which(_ tool: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { "\($0)/\(tool)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
