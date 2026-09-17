import Foundation
import Dispatch
import Darwin

/// No files, logs, temporary scripts, or output caches are created by this executor.
public enum CustomCommandProcess {
    public struct Output: Sendable {
        public let stdout: Data
        public let stderr: String
        public let exitCode: Int32
    }
    public static func run(command: String, timeout: TimeInterval = 15,
                           directory: URL = FileManager.default.homeDirectoryForCurrentUser,
                           environment: [String: String]? = nil) async throws -> Output {
        let state = State()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                state.start(command: command, timeout: timeout, directory: directory, environment: environment, continuation: continuation)
            }
        } onCancel: { state.cancel() }
    }

    // Every mutable field and POSIX/Dispatch handle is confined to queue. The box only
    // crosses executors to enqueue start/cancel; callbacks never access state off queue.
    private final class State: @unchecked Sendable {
        let queue = DispatchQueue(label: "org.agentisland.custom-command")
        var continuation: CheckedContinuation<Output, any Error>?
        var pid: pid_t = 0
        var stdout = Data(), stderr = Data()
        var readers: [DispatchSourceRead] = []
        var readable = Set<Int32>()
        var stdoutFD: Int32 = -1, stderrFD: Int32 = -1
        var processSource: DispatchSourceProcess?
        var deadline: DispatchWorkItem?
        var escalation: DispatchWorkItem?
        var failure: (any Error)?
        var exitCode: Int32?
        var stopping = false, cancelled = false, finished = false, escalated = false

        func start(command: String, timeout: TimeInterval, directory: URL, environment: [String: String]?,
                   continuation: CheckedContinuation<Output, any Error>) {
            queue.async { [self] in
                self.continuation = continuation
                guard !cancelled else { complete(.failure(CancellationError())); return }
                var out: [Int32] = [-1, -1], err: [Int32] = [-1, -1]
                guard pipe(&out) == 0 else { complete(.failure(CustomSourceError.launch)); return }
                guard pipe(&err) == 0 else {
                    out.forEach { _ = close($0) }; complete(.failure(CustomSourceError.launch)); return
                }
                defer { _ = close(out[1]); _ = close(err[1]) }
                for fd in out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
                var actions: posix_spawn_file_actions_t?
                var attributes: posix_spawnattr_t?
                guard posix_spawn_file_actions_init(&actions) == 0 else {
                    _ = close(out[0]); _ = close(err[0]); complete(.failure(CustomSourceError.launch)); return
                }
                defer { posix_spawn_file_actions_destroy(&actions) }
                guard posix_spawnattr_init(&attributes) == 0 else {
                    _ = close(out[0]); _ = close(err[0]); complete(.failure(CustomSourceError.launch)); return
                }
                defer { posix_spawnattr_destroy(&attributes) }
                // A group is established atomically at spawn, before zsh can fork a child.
                guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
                      posix_spawnattr_setpgroup(&attributes, 0) == 0,
                      posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
                      posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO) == 0,
                      posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO) == 0,
                      posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0 else {
                    _ = close(out[0]); _ = close(err[0]); complete(.failure(CustomSourceError.launch)); return
                }
                let arguments: [UnsafeMutablePointer<CChar>?] = ["/bin/zsh", "-lc", command].map { value in value.withCString { strdup($0) } } + [nil]
                // No additions in production; pass through the inherited environment.
                let values: [UnsafeMutablePointer<CChar>?] = (environment ?? ProcessInfo.processInfo.environment).map {
                    ($0.key + "=" + $0.value).withCString { strdup($0) }
                } + [nil]
                defer { arguments.forEach { free($0) }; values.forEach { free($0) } }
                let status: Int32 = arguments.withUnsafeBufferPointer { argv in
                    values.withUnsafeBufferPointer { env in
                        guard let argv = argv.baseAddress, let env = env.baseAddress else { return EINVAL }
                        return posix_spawn(&pid, "/bin/zsh", &actions, &attributes, argv, env)
                    }
                }
                guard status == 0 else {
                    pid = 0; _ = close(out[0]); _ = close(err[0]); complete(.failure(CustomSourceError.launch)); return
                }
                stdoutFD = out[0]; stderrFD = err[0]
                readable = [stdoutFD, stderrFD]
                for fd in [stdoutFD, stderrFD] {
                    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                    let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                    reader.setEventHandler { [weak self] in self?.drain(fd) }
                    reader.setCancelHandler { _ = close(fd) }
                    readers.append(reader); reader.resume()
                }
                let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
                source.setEventHandler { [self] in
                    var status: Int32 = 0
                    if waitpid(pid, &status, WNOHANG) == pid {
                        exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                        drain(stdoutFD); drain(stderrFD)
                        source.cancel(); processSource = nil
                        // Also clean up background children after a successful shell exit.
                        stop(nil)
                        finishIfReady()
                    }
                }
                processSource = source; source.resume()
                let deadline = DispatchWorkItem { [weak self] in self?.stop(CustomSourceError.timeout) }
                self.deadline = deadline
                queue.asyncAfter(deadline: .now() + max(0.01, timeout), execute: deadline)
            }
        }
        func drain(_ fd: Int32) {
            guard !finished, readable.contains(fd) else { return }
            var bytes = [UInt8](repeating: 0, count: 8192)
            // Bound each dispatch event so an endless stderr writer cannot starve cancellation.
            for _ in 0..<16 {
                let count = read(fd, &bytes, bytes.count)
                if count > 0 {
                    if fd == stdoutFD {
                        if stdout.count + count > 65536 { stop(CustomSourceError.outputTooLarge); return }
                        stdout.append(contentsOf: bytes.prefix(count))
                    } else if stderr.count < 512 { stderr.append(contentsOf: bytes.prefix(min(count, 512 - stderr.count))) }
                } else if count < 0 && errno == EINTR { continue }
                else {
                    if count == 0 { readable.remove(fd); readers.first { $0.handle == fd }?.cancel() }
                    return
                }
            }
        }
        func cancel() {
            queue.async { [self] in
                cancelled = true
                if continuation != nil { stop(CancellationError()) }
            }
        }
        func stop(_ error: (any Error)?) {
            guard !finished else { return }
            if failure == nil { failure = error }
            guard pid > 0 else { complete(.failure(failure ?? CustomSourceError.launch)); return }
            if !stopping {
                stopping = true; deadline?.cancel(); deadline = nil
                _ = kill(-pid, SIGTERM)
                let escalation = DispatchWorkItem { [self] in
                    if kill(-pid, 0) == 0 { _ = kill(-pid, SIGKILL) }
                    escalated = true
                    finishIfReady()
                }
                self.escalation = escalation
                queue.asyncAfter(deadline: .now() + 2, execute: escalation)
            }
            finishIfReady()
        }
        func finishIfReady() {
            guard exitCode != nil, escalated || kill(-pid, 0) != 0 else { return }
            if let failure { complete(.failure(failure)) }
            else { complete(.success(.init(stdout: stdout, stderr: String(decoding: stderr, as: UTF8.self), exitCode: exitCode ?? 1))) }
        }
        func complete(_ result: Result<Output, any Error>) {
            guard !finished else { return }
            finished = true
            deadline?.cancel(); escalation?.cancel()
            deadline = nil; escalation = nil
            readers.forEach { $0.cancel() }; readers.removeAll()
            processSource?.cancel(); processSource = nil
            continuation?.resume(with: result); continuation = nil
            stdout.removeAll(); stderr.removeAll()
        }
    }
}
