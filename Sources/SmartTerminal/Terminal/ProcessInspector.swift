import Darwin
import Foundation

/// libproc helpers to learn what a shell is doing without shell integration.
enum ProcessInspector {
    /// Current working directory of a process.
    static func cwd(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// Short executable name of a process ("vim", "ssh", "zsh").
    static func name(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// Process group currently in the foreground of the pty (the running command).
    static func foregroundGroup(ptyFD: Int32) -> pid_t? {
        guard ptyFD >= 0 else { return nil }
        let pgid = tcgetpgrp(ptyFD)
        return pgid > 0 ? pgid : nil
    }

    /// Full argv of a process, e.g. ["claude", "--dangerously-skip-permissions"]
    /// (argv[0] shortened to its last path component).
    static func arguments(of pid: pid_t) -> [String]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        // Layout: argc (int32), exec path, NUL padding, argv[0..argc-1], env...
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }  // skip exec path
        while i < size, buf[i] == 0 { i += 1 }  // skip padding
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        guard !args.isEmpty else { return nil }
        args[0] = (args[0] as NSString).lastPathComponent
        return args
    }

    /// Youngest process in the foreground group that is a direct child of the
    /// group leader, e.g. `caffeinate` under `claude`, as Terminal.app shows it.
    static func newestChild(ofLeader leader: pid_t) -> pid_t? {
        let count = proc_listchildpids(leader, nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let n = proc_listchildpids(leader, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return nil }
        let pgid = getpgid(leader)
        // Newest by start time, not by pid: pids wrap around.
        return pids.prefix(Int(n))
            .filter { $0 > 0 && getpgid($0) == pgid }
            .compactMap { pid in startTime(of: pid).map { (pid, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    static func startTime(of pid: pid_t) -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }
}
