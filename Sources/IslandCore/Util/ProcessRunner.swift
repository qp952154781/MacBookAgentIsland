import Foundation
import Dispatch
import Darwin

public struct ProcessOutput: Sendable, Equatable {
    public var stdout: Data
    public var exitCode: Int32
    public init(stdout: Data, exitCode: Int32) { self.stdout = stdout; self.exitCode = exitCode }
}

public enum ProcessRunnerError: Error, Sendable, Equatable {
    case timedOut
    case outputLimitExceeded
    case launchFailed(String)
}

public enum ProcessRunner {
    /// stderr is discarded and output is never logged. Timeout and cancellation terminate the child.
    public static func run(executableURL: URL, arguments: [String] = [], timeout: TimeInterval = 15,
                           environment: [String: String]? = nil, maxOutputBytes: Int = 16 * 1024 * 1024) async throws -> ProcessOutput {
        let state = State()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                state.start(executableURL: executableURL, arguments: arguments, timeout: timeout,
                            environment: environment, maxOutputBytes: maxOutputBytes, continuation: continuation)
            }
        } onCancel: { state.cancel() }
    }

    // Process, file descriptors, buffers, and the continuation are confined to a serial queue.
    // The Sendable box bridges Foundation/Dispatch callbacks without transferring mutable handles.
    private final class State: @unchecked Sendable {
        let queue = DispatchQueue(label: "org.agentisland.AgentIsland.ProcessRunner")
        var process: Process?
        var pipe: Pipe?
        var reader: DispatchSourceRead?
        var deadline: DispatchWorkItem?
        var continuation: CheckedContinuation<ProcessOutput, any Error>?
        var output = Data()
        var maxOutputBytes = 0
        var cancelled = false
        var finished = false

        func start(executableURL: URL, arguments: [String], timeout: TimeInterval,
                   environment: [String: String]?, maxOutputBytes: Int,
                   continuation: CheckedContinuation<ProcessOutput, any Error>) {
            queue.async {
                self.continuation = continuation
                guard !self.cancelled else { self.finish(.failure(CancellationError())); return }
                let process = Process()
                let pipe = Pipe()
                self.process = process
                self.pipe = pipe
                self.maxOutputBytes = max(0, maxOutputBytes)
                process.executableURL = executableURL
                process.arguments = arguments
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.terminationHandler = { [self] child in
                    let status = child.terminationStatus
                    queue.async { [self] in
                        drain()
                        finish(.success(ProcessOutput(stdout: output, exitCode: status)))
                    }
                }
                do { try process.run() }
                catch { self.finish(.failure(ProcessRunnerError.launchFailed(error.localizedDescription))); return }
                try? pipe.fileHandleForWriting.close()
                let fd = pipe.fileHandleForReading.fileDescriptor
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
                self.reader = source
                source.setEventHandler { [weak self] in self?.drain() }
                source.resume()
                let item = DispatchWorkItem { [weak self] in
                    self?.finish(.failure(ProcessRunnerError.timedOut))
                }
                self.deadline = item
                self.queue.asyncAfter(deadline: .now() + max(0, timeout), execute: item)
            }
        }

        func drain() {
            guard !finished, let pipe else { return }
            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                if count > 0 {
                    guard output.count + count <= maxOutputBytes else {
                        finish(.failure(ProcessRunnerError.outputLimitExceeded)); return
                    }
                    output.append(contentsOf: bytes.prefix(count))
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    if count == 0 { reader?.cancel(); reader = nil }
                    return
                }
            }
        }

        func cancel() {
            queue.async {
                self.cancelled = true
                if self.continuation != nil { self.finish(.failure(CancellationError())) }
            }
        }

        func finish(_ result: Result<ProcessOutput, any Error>) {
            guard !finished else { return }
            finished = true
            deadline?.cancel()
            deadline = nil
            reader?.cancel()
            reader = nil
            try? pipe?.fileHandleForReading.close()
            try? pipe?.fileHandleForWriting.close()
            pipe = nil
            if let process, process.isRunning {
                process.terminate()
                // A bounded escalation handles children that ignore SIGTERM. Process retains its PID until exit.
                queue.asyncAfter(deadline: .now() + 0.25) {
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                }
            }
            process?.terminationHandler = nil
            process = nil
            continuation?.resume(with: result)
            continuation = nil
            output.removeAll()
        }
    }
}
