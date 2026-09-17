import Foundation
import Testing
@testable import IslandCore

func quotaFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/quota"))
    return try Data(contentsOf: url)
}

func quotaTestDirectory() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let path = root.appendingPathComponent(".build/m1-test-data/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    return path
}

func eventually(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(await predicate())
}

func quotaSample(_ agent: ProviderID = .claude, at date: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> QuotaSnapshot {
    QuotaSnapshot(agent: agent, plan: "Pro", windows: [.init(id: "weekly", kind: .weekly, label: "本周", usedPercent: 17)],
                  source: agent == .claude ? .claudeOAuth : .codexAppServer, fetchedAt: date)
}

actor FakeQuotaExecutor: QuotaCommandExecuting {
    struct Call: Sendable { let executable: URL; let arguments: [String]; let timeout: TimeInterval }
    private var results: [Result<QuotaCommandOutput, QuotaError>]
    private(set) var calls: [Call] = []
    init(_ results: [Result<QuotaCommandOutput, QuotaError>]) { self.results = results }
    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) async throws -> QuotaCommandOutput {
        calls.append(Call(executable: executableURL, arguments: arguments, timeout: timeout))
        guard !results.isEmpty else { throw QuotaError.transient("fixture exhausted") }
        return try results.removeFirst().get()
    }
}

actor FakeUsageHTTP: UsageHTTPTransport {
    private var responses: [Result<UsageHTTPResponse, QuotaError>]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [Result<UsageHTTPResponse, QuotaError>]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> UsageHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw QuotaError.transient("fixture exhausted") }
        return try responses.removeFirst().get()
    }
}

// Immutable fixture chunks plus lock-confined stream lifecycle and observations.
final class FakeRPCTransport: JSONRPCTransport, @unchecked Sendable {
    let chunks: [Data]
    let end: Bool
    private let lock = NSLock()
    private var stream: AsyncThrowingStream<Data, any Error>.Continuation?
    private var closed = false
    private var sent: [Data] = []
    private var starts = 0
    init(chunks: [Data] = [], end: Bool = true) { self.chunks = chunks; self.end = end }
    func start(executableURL: URL) async throws -> AsyncThrowingStream<Data, any Error> {
        let pair = AsyncThrowingStream<Data, any Error>.makeStream()
        lock.withLock {
            starts += 1; stream = pair.continuation
            if closed { pair.continuation.finish(throwing: CancellationError()); return }
            chunks.forEach { pair.continuation.yield($0) }
            if end { pair.continuation.finish() }
        }
        return pair.stream
    }
    func send(_ data: Data) async throws { lock.withLock { sent.append(data) } }
    func close() { lock.withLock { closed = true; stream?.finish(throwing: CancellationError()); stream = nil } }
    var isClosed: Bool { lock.withLock { closed } }
    var messages: [Data] { lock.withLock { sent } }
    var startCount: Int { lock.withLock { starts } }
}

// All virtual time and continuation state is protected by lock. Resumes happen outside it.
final class FakeQuotaClock: QuotaClock, @unchecked Sendable {
    private struct Waiter { let deadline: Date; let continuation: CheckedContinuation<Void, any Error> }
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    private var waiters: [UUID: Waiter] = [:]
    private var cancelled: Set<UUID> = []
    private var durations: [Double] = []
    func now() -> Date { lock.withLock { date } }
    var sleeps: [Double] { lock.withLock { durations } }
    var pending: Int { lock.withLock { waiters.count } }
    func sleep(for seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancel = lock.withLock {
                    if cancelled.remove(id) != nil || Task.isCancelled { return true }
                    durations.append(seconds)
                    waiters[id] = Waiter(deadline: date.addingTimeInterval(seconds), continuation: continuation)
                    return false
                }
                if cancel { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = self.lock.withLock {
                let waiter = self.waiters.removeValue(forKey: id)
                if waiter == nil { self.cancelled.insert(id) }
                return waiter
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }
    func advance(_ seconds: Double) {
        let ready = lock.withLock {
            date.addTimeInterval(seconds)
            let ready = waiters.filter { $0.value.deadline <= date }
            for key in ready.keys { waiters[key] = nil }
            return Array(ready.values)
        }
        ready.forEach { $0.continuation.resume() }
    }
}

actor SequenceQuotaProvider: QuotaProviding, CodexRolloutReading {
    nonisolated let agent: ProviderID
    private var results: [Result<QuotaSnapshot, QuotaError>]
    private(set) var count = 0
    init(agent: ProviderID = .claude, _ results: [Result<QuotaSnapshot, QuotaError>]) { self.agent = agent; self.results = results }
    func fetchQuota() async throws -> QuotaSnapshot {
        count += 1
        guard !results.isEmpty else { throw QuotaError.transient("fixture exhausted") }
        let result = results.count == 1 ? results[0] : results.removeFirst()
        return try result.get()
    }
}

actor QuotaUpdateLog {
    private(set) var values: [QuotaUpdate] = []
    func append(_ value: QuotaUpdate) { values.append(value) }
}
