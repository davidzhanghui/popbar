import Foundation

/// 唯一的子进程执行入口（静态检查保证 Sources 里除本文件外不出现 `Process()`）。
///
/// 以前有五套各自的写法，其中几套不读 stderr、或等进程结束才读 stdout，输出超过管道缓冲
/// （约 64KB）就会互相卡死，最后误报「超时」。这里统一处理：
///
/// - stdout / stderr 各一个读取任务并发读完，不会因为缓冲写满而卡住；
/// - stdin 在单独的任务里写；对方不读就退出时只得到 EPIPE（启动时已忽略 SIGPIPE，见 `ignoreSIGPIPE`）；
/// - 子进程放进独立进程组（posix_spawn + POSIX_SPAWN_SETPGROUP），超时先 SIGTERM 整组，
///   2 秒后 SIGKILL，脚本派生出来的子进程也一起结束；
/// - stdout 超过上限就截断并标记，继续读空管道，避免失控的命令吃光内存或卡在写上。
///
/// 参考实现：Decklet `decklet-core/src/shell.rs`。
public enum Shell {
    /// 进程启动时调用一次
    public static func ignoreSIGPIPE() {
        signal(SIGPIPE, SIG_IGN)
    }

    public enum Status: Equatable, Sendable {
        case exited(Int32)
        /// 被信号结束（非超时）
        case signaled(Int32)
        case timedOut
        /// 启动失败（可执行文件不存在等）
        case spawnFailed(String)
    }

    public struct Output: Sendable {
        public var status: Status
        public var stdout: Data
        public var stderr: String
        /// stdout 超过上限被截断
        public var truncated: Bool

        public var ok: Bool { status == .exited(0) }
        public var text: String { String(decoding: stdout, as: UTF8.self) }
        /// 退出码；超时 -2，启动失败 -1，被信号结束 128+信号
        public var code: Int32 {
            switch status {
            case .exited(let c): return c
            case .signaled(let s): return 128 + s
            case .timedOut: return -2
            case .spawnFailed: return -1
            }
        }

        /// 给人看的失败原因；成功时为空串
        public var error: String {
            switch status {
            case .exited(0): return ""
            case .exited(let c):
                let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if e.isEmpty { return L10n.t("退出码 \(c)", "exit code \(c)") }
                return e.split(separator: "\n").last.map(String.init) ?? e
            case .signaled: return L10n.t("进程被终止", "Process was killed")
            case .timedOut: return L10n.t("执行超时，已终止", "Timed out and was stopped")
            case .spawnFailed(let e): return L10n.t("无法启动：\(e)", "Cannot start: \(e)")
            }
        }
    }

    public struct Request: Sendable {
        public var executable: String
        public var arguments: [String]
        public var stdin: Data?
        /// 追加到当前环境变量之上
        public var environment: [String: String]
        public var timeout: TimeInterval
        /// stdout 上限（字节），默认 4MB
        public var maxOutput: Int
        public var currentDirectory: String?

        public init(_ executable: String, _ arguments: [String] = [], stdin: Data? = nil,
                    environment: [String: String] = [:], timeout: TimeInterval = 60,
                    maxOutput: Int = 4 << 20, currentDirectory: String? = nil) {
            self.executable = executable
            self.arguments = arguments
            self.stdin = stdin
            self.environment = environment
            self.timeout = timeout
            self.maxOutput = maxOutput
            self.currentDirectory = currentDirectory
        }
    }

    // MARK: - 便捷入口

    /// 同步执行（只在后台线程调用）
    public static func run(_ executable: String, _ arguments: [String] = [], stdin: Data? = nil,
                           environment: [String: String] = [:], timeout: TimeInterval = 60,
                           maxOutput: Int = 4 << 20) -> Output {
        exec(Request(executable, arguments, stdin: stdin, environment: environment,
                     timeout: timeout, maxOutput: maxOutput))
    }

    /// 异步执行：放到全局队列里跑，不阻塞调用方
    public static func run(_ request: Request) async -> Output {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async { cont.resume(returning: exec(request)) }
        }
    }

    /// `sh -c`：脚本经参数传入，文本只走 stdin / 环境变量，绝不拼进命令串
    public static func sh(_ script: String, stdin: Data? = nil, environment: [String: String] = [:],
                          timeout: TimeInterval = 60, maxOutput: Int = 4 << 20) -> Output {
        run("/bin/sh", ["-c", script], stdin: stdin, environment: environment,
            timeout: timeout, maxOutput: maxOutput)
    }

    // MARK: - 核心

    public static func exec(_ r: Request) -> Output {
        var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            return Output(status: .spawnFailed(String(cString: strerror(errno))), stdout: Data(), stderr: "", truncated: false)
        }
        let hasStdin = r.stdin != nil
        if hasStdin, pipe(&inPipe) != 0 {
            [outPipe[0], outPipe[1], errPipe[0], errPipe[1]].forEach { close($0) }
            return Output(status: .spawnFailed(String(cString: strerror(errno))), stdout: Data(), stderr: "", truncated: false)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if hasStdin {
            posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        // 子进程里关掉所有父进程的管道端
        for fd in [inPipe[0], inPipe[1], outPipe[0], outPipe[1], errPipe[0], errPipe[1]] where fd > 2 {
            posix_spawn_file_actions_addclose(&actions, fd)
        }
        if let cwd = r.currentDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, cwd)
        }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // 独立进程组（pgid = 子进程 pid），超时 killpg 整组；信号处理恢复默认（父进程忽略了 SIGPIPE）
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawnattr_setflags(&attr, flags)
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)

        var env = ProcessInfo.processInfo.environment
        for (k, v) in r.environment { env[k] = v }
        let argv = [r.executable] + r.arguments
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cArgs.forEach { free($0) }; cEnv.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, r.executable, &actions, &attr, cArgs, cEnv)
        // 父进程关掉子进程那一端
        close(outPipe[1]); close(errPipe[1])
        if hasStdin { close(inPipe[0]) }
        if rc != 0 {
            close(outPipe[0]); close(errPipe[0])
            if hasStdin { close(inPipe[1]) }
            return Output(status: .spawnFailed(String(cString: strerror(rc))), stdout: Data(), stderr: "", truncated: false)
        }

        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var _data = Data()
            private var _truncated = false
            var count: Int { lock.withLock { _data.count } }
            func append(_ bytes: ArraySlice<UInt8>) { lock.withLock { _data.append(contentsOf: bytes) } }
            func markTruncated() { lock.withLock { _truncated = true } }
            var data: Data { lock.withLock { _data } }
            var truncated: Bool { lock.withLock { _truncated } }
        }
        let outBox = Box(), errBox = Box()
        let group = DispatchGroup()
        let q = DispatchQueue.global(qos: .utility)

        if hasStdin, let data = r.stdin {
            let fd = inPipe[1]
            group.enter()
            q.async {
                // 对方不读 stdin 就退出时 write 返回 EPIPE，忽略即可
                data.withUnsafeBytes { raw in
                    guard var p = raw.baseAddress else { return }
                    var left = raw.count
                    while left > 0 {
                        let n = write(fd, p, left)
                        if n < 0 { if errno == EINTR { continue }; break }
                        left -= n
                        p = p.advanced(by: n)
                    }
                }
                close(fd)
                group.leave()
            }
        }
        for (fd, box, cap) in [(outPipe[0], outBox, r.maxOutput), (errPipe[0], errBox, 256 << 10)] {
            group.enter()
            q.async {
                var chunk = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = read(fd, &chunk, chunk.count)
                    if n < 0 { if errno == EINTR { continue }; break }
                    if n == 0 { break }
                    let have = box.count
                    if have < cap {
                        let take = min(n, cap - have)
                        box.append(chunk[0..<take])
                        if take < n { box.markTruncated() }
                    } else {
                        box.markTruncated()   // 继续读空管道，避免子进程卡在写上
                    }
                }
                close(fd)
                group.leave()
            }
        }

        // 等待退出：轮询 waitpid，超时 SIGTERM 整组，2 秒后 SIGKILL
        let deadline = Date().addingTimeInterval(r.timeout)
        var status: Int32 = 0
        var timedOut = false
        var termSentAt: Date?
        while true {
            let w = waitpid(pid, &status, WNOHANG)
            if w == pid { break }
            if w < 0 && errno != EINTR { break }
            let now = Date()
            if let t = termSentAt {
                if now.timeIntervalSince(t) > 2 { killpg(pid, SIGKILL); kill(pid, SIGKILL) }
            } else if now > deadline {
                timedOut = true
                killpg(pid, SIGTERM)
                kill(pid, SIGTERM)
                termSentAt = now
            }
            usleep(timedOut ? 20_000 : 2_000)
        }
        // 进程退出后，孙进程可能仍握着管道写端；超时场景下给读取任务一个上限
        if timedOut {
            killpg(pid, SIGKILL)
            _ = group.wait(timeout: .now() + 2)
        } else if group.wait(timeout: .now() + 5) == .timedOut {
            killpg(pid, SIGKILL)
            _ = group.wait(timeout: .now() + 1)
        }

        let st: Status
        if timedOut {
            st = .timedOut
        } else if (status & 0x7f) == 0 {
            st = .exited((status >> 8) & 0xff)
        } else {
            st = .signaled(status & 0x7f)
        }
        return Output(status: st, stdout: outBox.data,
                      stderr: String(decoding: errBox.data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      truncated: outBox.truncated)
    }

    /// 单引号转义，供需要拼接固定命令的地方使用（外部文本仍应走 stdin）
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
