import Foundation
import Dispatch
import Darwin

public struct QuotaCommandOutput: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let stdout: Data
    public let exitCode: Int32
    public let itemNotFound: Bool
    public init(stdout: Data, exitCode: Int32, itemNotFound: Bool = false) {
        self.stdout = stdout; self.exitCode = exitCode; self.itemNotFound = itemNotFound
    }
    public var description: String { "QuotaCommandOutput(exitCode: \(exitCode), output: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["exitCode": exitCode]) }
}

public protocol QuotaCommandExecuting: Sendable {
    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) async throws -> QuotaCommandOutput
}

public struct QuotaCommandExecutor: QuotaCommandExecuting {
    public init() {}
    public func run(executableURL: URL, arguments: [String], timeout: TimeInterval) async throws -> QuotaCommandOutput {
        try await ProcessRunner.runQuotaCommand(executableURL: executableURL, arguments: arguments, timeout: timeout)
    }
}

public extension ProcessRunner {
    /// Quota-local adapter: stderr is reduced to a missing-keychain-item flag, never returned or logged.
    static func runQuotaCommand(executableURL: URL, arguments: [String], timeout: TimeInterval) async throws -> QuotaCommandOutput {
        let process = QuotaProcess()
        return try await withTaskCancellationHandler {
            defer { process.close() }
            try Task.checkCancellation()
            let stream = process.start(executableURL: executableURL, arguments: arguments,
                                       timeout: timeout, inspectStandardError: true, interactive: false)
            var data = Data()
            for try await chunk in stream { try Task.checkCancellation(); data.append(chunk) }
            try Task.checkCancellation()
            let status = process.status()
            return QuotaCommandOutput(stdout: data, exitCode: status.0, itemNotFound: status.1)
        } onCancel: { process.close() }
    }
}

// All Process/pipe/source state is confined to queue. Continuations are delivered on the
// separate delivery queue so task cancellation can never form a lock cycle with this queue.
final class QuotaProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.agentisland.AgentIsland.QuotaProcess")
    private let deliveryQueue = DispatchQueue(label: "org.agentisland.AgentIsland.QuotaProcess.delivery")
    private let queueTeardownHook: @Sendable () -> Void
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var errors: Pipe?
    private var readers: [DispatchSourceRead] = []
    private var deadline: DispatchWorkItem?
    private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private var finished = false
    private var started = false
    private var bytesRead = 0
    private var errorSuffix = Data()
    private var missing = false
    private var exitCode: Int32 = -1

    init(queueTeardownHook: @escaping @Sendable () -> Void = {}) {
        self.queueTeardownHook = queueTeardownHook
    }

    func start(executableURL: URL, arguments: [String], timeout: TimeInterval,
               inspectStandardError: Bool = false, interactive: Bool = true) -> AsyncThrowingStream<Data, any Error> {
        let pair = AsyncThrowingStream<Data, any Error>.makeStream()
        queue.async {
            guard !self.finished, !self.started else {
                self.deliveryQueue.async { pair.continuation.finish(throwing: CancellationError()) }
                return
            }
            self.started = true
            self.continuation = pair.continuation
            let child = Process(), output = Pipe()
            self.process = child; self.output = output
            child.executableURL = executableURL; child.arguments = arguments
            child.standardOutput = output
            if interactive {
                let input = Pipe(); self.input = input; child.standardInput = input
                let fd = input.fileHandleForWriting.fileDescriptor
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            } else { child.standardInput = FileHandle.nullDevice }
            if inspectStandardError {
                let errors = Pipe(); self.errors = errors; child.standardError = errors
            } else { child.standardError = FileHandle.nullDevice }
            child.terminationHandler = { [weak self] child in
                let status = child.terminationStatus
                self?.queue.async { [weak self] in
                    guard let self, !self.finished else { return }
                    self.drain(self.output, isError: false)
                    self.drain(self.errors, isError: true)
                    self.exitCode = status
                    self.finish(nil)
                }
            }
            do { try child.run() }
            catch { self.finish(QuotaError.transient("无法启动额度查询进程")); return }
            try? self.input?.fileHandleForReading.close()
            for (pipe, isError) in [(self.output, false), (self.errors, true)] {
                guard let pipe else { continue }
                try? pipe.fileHandleForWriting.close()
                let fd = pipe.fileHandleForReading.fileDescriptor
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
                source.setEventHandler { [weak self, weak source] in
                    guard let self else { return }
                    if self.drain(pipe, isError: isError) { source?.cancel() }
                }
                self.readers.append(source); source.resume()
            }
            let timer = DispatchWorkItem { [weak self] in self?.finish(QuotaError.transient("额度查询超时")) }
            self.deadline = timer
            self.queue.asyncAfter(deadline: .now() + max(0, timeout), execute: timer)
        }
        return pair.stream
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard !self.finished, let input = self.input else {
                    self.deliveryQueue.async {
                        result.resume(throwing: QuotaError.transient("额度查询进程已关闭"))
                    }
                    return
                }
                let count = data.withUnsafeBytes { bytes in
                    Darwin.write(input.fileHandleForWriting.fileDescriptor, bytes.baseAddress, bytes.count)
                }
                guard count == data.count else {
                    self.finish(QuotaError.transient("额度查询通信失败"))
                    self.deliveryQueue.async {
                        result.resume(throwing: QuotaError.transient("额度查询通信失败"))
                    }
                    return
                }
                self.deliveryQueue.async { result.resume() }
            }
        }
    }

    /// Cancellation callbacks and deinitializers must only enqueue here; they must never wait
    /// synchronously for code on this queue.
    func close() { queue.async { self.finish(CancellationError()) } }

    /// Normal-path inspection only. Code on `queue` must never be synchronously awaited by a
    /// cancellation callback; doing so can invert Swift task-status and Dispatch queue locks.
    func status() -> (Int32, Bool) { queue.sync { (exitCode, missing) } }

    @discardableResult private func drain(_ pipe: Pipe?, isError: Bool) -> Bool {
        guard !finished, let pipe else { return true }
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        while !finished {
            let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                bytesRead += count
                guard bytesRead <= 2 * 1024 * 1024 else { finish(QuotaError.transient("额度查询响应过大")); return true }
                let data = Data(bytes.prefix(count))
                if isError {
                    errorSuffix.append(data)
                    if String(decoding: errorSuffix, as: UTF8.self).localizedCaseInsensitiveContains("could not be found") { missing = true }
                    errorSuffix = Data(errorSuffix.suffix(32))
                } else if let continuation {
                    deliveryQueue.async { continuation.yield(data) }
                }
            } else if count < 0 && errno == EINTR { continue }
            else { return count == 0 }
        }
        return true
    }

    private func finish(_ error: (any Error)?) {
        guard !finished else { return }
        finished = true
        deadline?.cancel(); deadline = nil
        readers.forEach { $0.cancel() }; readers.removeAll()
        for pipe in [input, output, errors] {
            try? pipe?.fileHandleForWriting.close(); try? pipe?.fileHandleForReading.close()
        }
        input = nil; output = nil; errors = nil; errorSuffix.removeAll()
        if let child = process, child.isRunning {
            child.terminate()
            queue.asyncAfter(deadline: .now() + 0.25) {
                if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            }
        }
        process?.terminationHandler = nil; process = nil
        queueTeardownHook()
        let continuation = continuation
        self.continuation = nil
        if let continuation {
            deliveryQueue.async { continuation.finish(throwing: error) }
        }
    }
}
