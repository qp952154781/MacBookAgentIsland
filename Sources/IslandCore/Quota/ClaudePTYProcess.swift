import Foundation
import Dispatch
import Darwin

/// Actor confinement covers Process, descriptors, and source callbacks. No terminal output is logged.
public actor ClaudePTYProcess: ClaudePTY {
    private var child: Process?
    private var master: Int32 = -1
    private var reader: DispatchSourceRead?
    private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private var closed = false
    private var input = ClaudePTYInputSequence()
    private var cleanupTask: Task<Void, Never>?
    public init() {}
    public func start(executable: URL, directory: URL) throws -> AsyncThrowingStream<Data, any Error> {
        guard !closed, cleanupTask == nil, child == nil else { throw CancellationError() }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var slave: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw QuotaError.transient("无法创建续期终端") }
        let handle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        defer { try? handle.close() }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        _ = fcntl(master, F_SETNOSIGPIPE, 1)
        let process = Process()
        process.executableURL = executable; process.arguments = ["--no-chrome", "--settings", #"{"remoteControlAtStartup":false}"#]; process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        process.standardInput = handle; process.standardOutput = handle; process.standardError = handle
        let pair = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        continuation = pair.continuation
        process.terminationHandler = { [weak self] _ in Task { await self?.ended() } }
        do { try process.run() }
        catch { closePTY(); throw QuotaError.transient("无法启动 Claude 续期进程") }
        child = process
        let source = DispatchSource.makeReadSource(fileDescriptor: master)
        source.setEventHandler { [weak self] in Task { await self?.drain() } }
        reader = source; source.resume()
        return pair.stream
    }
    private func drain() {
        guard master >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(master, &buffer, buffer.count)
            if count > 0 {
                if case .dropped = continuation?.yield(Data(buffer.prefix(count))) {
                    continuation?.finish(throwing: QuotaError.transient("续期终端输出过多")); return
                }
            } else if count < 0 && errno == EINTR { continue }
            else { return }
        }
    }
    private func ended() { drain(); continuation?.finish() }
    public func send(_ text: String) throws {
        guard !closed, master >= 0, child?.isRunning == true else { throw QuotaError.transient("续期终端已关闭") }
        guard input.allows(text), cleanupTask == nil || text != "/usage\r" else {
            throw QuotaError.transient("续期终端输入阶段无效")
        }
        let bytes = Array(text.utf8)
        let count = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw QuotaError.transient("续期终端写入失败") }
        input.didSend(text)
    }
    public func finish(graceful: Bool) async {
        // Detached cleanup is deliberately not cancelled with the caller.
        if let cleanupTask { await cleanupTask.value; return }
        let cleanup = Task.detached { await self.cleanup(graceful: graceful) }
        cleanupTask = cleanup
        await cleanup.value
    }
    private func cleanup(graceful: Bool) async {
        guard !closed else { return }
        if graceful, input.usageSent, child?.isRunning == true {
            do {
                if input.allows("\u{1b}") { try send("\u{1b}") }
                if input.allows("/exit\r") { try send("/exit\r") }
                await wait(seconds: 3)
            } catch { /* Failed graceful input falls through to TERM / KILL. */ }
        }
        if let child, child.isRunning {
            child.terminate()
            await wait(seconds: 2)
            if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }
        child?.terminationHandler = nil; child = nil
        closed = true; closePTY()
    }
    private func wait(seconds: Double) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while child?.isRunning == true, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }
    private func closePTY() {
        reader?.cancel(); reader = nil
        if master >= 0 { Darwin.close(master); master = -1 }
        continuation?.finish(); continuation = nil
    }
}

/// The only permitted input sequence, shared by transport validation and fixture transports.
struct ClaudePTYInputSequence: Sendable {
    private var index = 0
    private static let commands = ["/usage\r", "\u{1b}", "/exit\r"]
    var usageSent: Bool { index > 0 }
    func allows(_ text: String) -> Bool {
        index < Self.commands.count && text == Self.commands[index]
    }
    mutating func didSend(_ text: String) {
        if allows(text) { index += 1 }
    }
}
