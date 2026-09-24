import Foundation
import Testing
import SQLite3
import Darwin
@testable import IslandCore

private final class TimeoutRaceGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func holdTeardown() {
        entered.signal()
        release.wait()
    }

    func waitUntilTeardown() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.entered.wait(timeout: .now() + 1) == .success)
            }
        }
    }

    func resumeTeardown(after microseconds: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + .microseconds(microseconds)) {
            self.release.signal()
        }
    }
}

private final class TimeoutRaceTransport: JSONRPCTransport, @unchecked Sendable {
    private let process: QuotaProcess

    init(gate: TimeoutRaceGate) {
        process = QuotaProcess(queueTeardownHook: { gate.holdTeardown() })
    }

    func start(executableURL: URL) async throws -> AsyncThrowingStream<Data, any Error> {
        process.start(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                      timeout: 0.002, interactive: false)
    }

    func send(_ data: Data) async throws {}
    func close() { process.close() }
}

private final class CloseReturnProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var returned = false

    func markReturned() { lock.withLock { returned = true } }
    var hasReturned: Bool { lock.withLock { returned } }
}

@Test func rpcFramingHandshakeNotificationsAndClosure() async throws {
    let data = try quotaFixture("rpc-stream.jsonl")
    // Every byte is its own chunk, including non-ASCII/line boundaries.
    let transport = FakeRPCTransport(chunks: data.map { Data([$0]) })
    let client = CodexAppServerClient(locate: { URL(fileURLWithPath: "/fixture/codex") }, makeTransport: { transport })
    let result = try await client.fetchQuota()
    #expect(result.plan == "pro")
    #expect(result.windows.count == 5)
    #expect(transport.isClosed)
    let sent = try transport.messages.map { try QuotaJSON.parse($0) }
    #expect(sent.map { $0["method"].string } == ["initialize", "initialized", "account/rateLimits/read"])
    #expect(sent[0]["params"]["clientInfo"]["name"].string == "agent-island")
    #expect(sent[0]["id"].integer == 1)
    #expect(sent[2]["id"].integer == 2)
    let batched = FakeRPCTransport(chunks: [data])
    _ = try await CodexAppServerClient(locate: { URL(fileURLWithPath: "/fixture/codex") }, makeTransport: { batched }).fetchQuota()
    #expect(batched.messages.count == 3)
    #expect(batched.isClosed)
}

@Test func rpcErrorEOFInvalidResultAndMissingExecutable() async throws {
    let errorData = Data(#"{"id":1,"result":{}}"#.utf8) + Data([10]) + (try quotaFixture("rpc-error.json"))
    for data in [errorData, Data(), Data("{\"id\":1,\"result\":{}}\n{\"id\":2,\"result\":{}}\n".utf8)] {
        let transport = FakeRPCTransport(chunks: [data])
        do {
            _ = try await CodexAppServerClient(locate: { URL(fileURLWithPath: "/fixture/codex") }, makeTransport: { transport }).fetchQuota()
            Issue.record("Expected failure")
        } catch {
            #expect(error is QuotaError)
            #expect(!String(describing: error).contains("sk-ant-oat01-FAKE-ACCESS"))
        }
        #expect(transport.isClosed)
    }
    let missing = FakeRPCTransport()
    await #expect(throws: QuotaError.notConfigured("未找到 Codex")) {
        try await CodexAppServerClient(locate: { nil }, makeTransport: { missing }).fetchQuota()
    }
    #expect(missing.startCount == 0)
    #expect(missing.isClosed)
}

@Test func rpcTimeoutAndCancellationAlwaysClose() async throws {
    let stalled = FakeRPCTransport(end: false)
    await #expect(throws: QuotaError.transient("Codex 额度查询超时")) {
        try await CodexAppServerClient(locate: { URL(fileURLWithPath: "/fixture/codex") }, makeTransport: { stalled }, timeout: 0.03).fetchQuota()
    }
    #expect(stalled.isClosed)
    let cancelled = FakeRPCTransport(end: false)
    let task = Task {
        try await CodexAppServerClient(locate: { URL(fileURLWithPath: "/fixture/codex") }, makeTransport: { cancelled }).fetchQuota()
    }
    try await eventually { cancelled.startCount == 1 }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(cancelled.isClosed)
}

@Test func rolloutScanBoundsAndNoData() async throws {
    let directory = try quotaTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = try #require(DateParsing.iso8601("2026-09-11T00:00:00Z"))
    let today = directory.appendingPathComponent("sessions/2026/09/11")
    let old = directory.appendingPathComponent("sessions/2026/09/09")
    try FileManager.default.createDirectory(at: today, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    let reader = CodexRolloutQuotaReader(directory: directory, now: { now })
    await #expect(throws: QuotaError.notConfigured("未找到 Codex rollout")) { try await reader.fetchQuota() }
    try quotaFixture("rollout.jsonl").write(to: old.appendingPathComponent("rollout-old.jsonl"))
    await #expect(throws: QuotaError.notConfigured("未找到 Codex rollout")) { try await reader.fetchQuota() }
    let path = today.appendingPathComponent("rollout-fixture.jsonl")
    let padding = Data(repeating: 120, count: 600 * 1024)
    // A valid record before the tail must never be observed.
    try (quotaFixture("rollout.jsonl") + padding + Data("\nbad\n".utf8)).write(to: path)
    await #expect(throws: QuotaError.decoding("Codex rollout 中没有可用额度")) { try await reader.fetchQuota() }
    try (padding + Data([10]) + quotaFixture("rollout.jsonl")).write(to: path)
    let snapshot = try await reader.fetchQuota()
    #expect(snapshot.weekly?.usedPercent == 39)
    #expect(snapshot.fetchedAt == now)
}

@Test func rolloutReadOnlySQLiteAndNewestRecord() async throws {
    let directory = try quotaTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = try #require(DateParsing.iso8601("2026-09-11T00:00:00Z"))
    let one = directory.appendingPathComponent("rollout-one.jsonl")
    let two = directory.appendingPathComponent("rollout-two.jsonl")
    try quotaFixture("rollout.jsonl").write(to: one)
    let newer = String(decoding: try quotaFixture("rollout.jsonl"), as: UTF8.self)
        .replacingOccurrences(of: "2026-09-11T00:00:00Z", with: "2026-09-11T01:00:00Z")
        .replacingOccurrences(of: "39", with: "41")
    try Data(newer.utf8).write(to: two)
    var db: OpaquePointer?
    let database = directory.appendingPathComponent("state_5.sqlite")
    #expect(sqlite3_open(database.path, &db) == SQLITE_OK)
    let sql = "CREATE TABLE threads (rollout_path TEXT, updated_at_ms INTEGER); INSERT INTO threads VALUES ('\(one.path)', 200), ('\(two.path)', 100);"
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let before = try Data(contentsOf: database)
    let reader = CodexRolloutQuotaReader(directory: directory, now: { now })
    let snapshot = try await reader.fetchQuota()
    #expect(snapshot.weekly?.usedPercent == 41)
    #expect(snapshot.fetchedAt == now.addingTimeInterval(3600))
    #expect(try Data(contentsOf: database) == before)
}

@Test func codexProviderFallbackPreservesPrimaryError() async throws {
    let snapshot = quotaSample(.codex)
    let fallback = SequenceQuotaProvider(agent: .codex, [.success(snapshot)])
    let provider = CodexQuotaProvider(appServer: { throw QuotaError.transient("fixture") }, rollout: fallback)
    #expect(try await provider.fetchQuota() == snapshot)
    let missing = SequenceQuotaProvider(agent: .codex, [.failure(.notConfigured("missing"))])
    await #expect(throws: QuotaError.notConfigured("未找到 Codex")) {
        try await CodexQuotaProvider(appServer: { throw QuotaError.notConfigured("missing") }, rollout: missing).fetchQuota()
    }
    let bad = SequenceQuotaProvider(agent: .codex, [.failure(.decoding("last"))])
    await #expect(throws: QuotaError.transient("first")) {
        try await CodexQuotaProvider(appServer: { throw QuotaError.transient("first") }, rollout: bad).fetchQuota()
    }
    await #expect(throws: CancellationError.self) {
        try await CodexQuotaProvider(appServer: { throw CancellationError() }, rollout: bad).fetchQuota()
    }
    #expect(await bad.count == 1)
    let primary = CodexQuotaProvider(appServer: { snapshot }, rollout: fallback)
    #expect(try await primary.fetchQuota() == snapshot)
    #expect(await fallback.count == 1)
}

@Test func quotaProcessClassifiesStderrAndDiscardsIt() async throws {
    // Generic fixture commands only: never security, Codex, Claude, or network.
    let output = try await ProcessRunner.runQuotaCommand(executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf 'fixture'; printf 'could not be found' >&2; exit 7"], timeout: 1)
    #expect(output.stdout == Data("fixture".utf8))
    #expect(output.exitCode == 7)
    #expect(output.itemNotFound)
    #expect(!String(describing: output).contains("fixture"))
}

@Test func quotaProcessTimeoutCancellationAndKillEscalation() async throws {
    let process = QuotaProcess()
    let stream = process.start(executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf '%s\\n' $$; trap '' TERM; exec /bin/sleep 30"], timeout: 0.08, interactive: false)
    var pid: Int32?
    do {
        for try await chunk in stream { pid = Int32(String(decoding: chunk, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
        Issue.record("Expected timeout")
    } catch { #expect(error is QuotaError) }
    let child = try #require(pid)
    try await eventually { kill(child, 0) != 0 && errno == ESRCH }
    process.close()
    let task = Task {
        try await ProcessRunner.runQuotaCommand(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 10)
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func quotaProcessTimeoutCancellationRaceDoesNotDeadlock() async {
    // Hold the real process-timeout teardown until cancellation reaches the competing task path.
    var random = UInt64(0x17_C0DE)
    for _ in 0..<200 {
        random = random &* 6_364_136_223_846_793_005 &+ 1
        let cancellationJitter = Int(random % 5_001)
        let rpcTimeout = 0.020 + Double(cancellationJitter) / 1_000_000
        let gate = TimeoutRaceGate()
        let transport = TimeoutRaceTransport(gate: gate)
        let client = CodexAppServerClient(
            locate: { URL(fileURLWithPath: "/fixture/codex") },
            makeTransport: { transport },
            timeout: rpcTimeout
        )
        let task = Task { try await client.fetchQuota() }
        #expect(await gate.waitUntilTeardown())
        gate.resumeTeardown(after: 30_000 + cancellationJitter)
        do {
            _ = try await task.value
            Issue.record("Expected timeout or cancellation")
        } catch {
            #expect(error is QuotaError || error is CancellationError)
        }
    }
}

@Test func quotaProcessCloseNeverWaitsForBusyTeardownQueue() async throws {
    let gate = TimeoutRaceGate()
    let transport = TimeoutRaceTransport(gate: gate)
    let stream = try await transport.start(executableURL: URL(fileURLWithPath: "/fixture/ignored"))
    let consumer = Task {
        do { for try await _ in stream {} }
        catch { #expect(error is QuotaError || error is CancellationError) }
    }
    #expect(await gate.waitUntilTeardown())

    let probe = CloseReturnProbe()
    DispatchQueue.global().async {
        transport.close()
        probe.markReturned()
    }
    try await Task.sleep(for: .milliseconds(10))
    let returnedBeforeRelease = probe.hasReturned
    gate.resumeTeardown(after: 0)
    try await eventually { probe.hasReturned }
    await consumer.value

    #expect(returnedBeforeRelease)
}

@Test func stdioTransportWithHandwrittenExecutableFixture() async throws {
    let directory = try quotaTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("rpc-fixture.sh")
    let body = """
    #!/bin/sh
    IFS= read -r initialize
    printf '%s\\n' '{"id":1,"result":{}}' '{"method":"remoteControl/status/changed"}'
    IFS= read -r initialized
    IFS= read -r query
    printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":39,"windowDurationMins":10080},"planType":"pro"}}}'
    IFS= read -r eof
    """
    try Data(body.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let client = CodexAppServerClient(locate: { script }, makeTransport: { StdioJSONRPCTransport() })
    let snapshot = try await client.fetchQuota()
    #expect(snapshot.plan == "pro")
    #expect(snapshot.weekly?.usedPercent == 39)
}

@Test func rolloutRejectsSymlinksToNonRolloutFiles() async throws {
    let directory = try quotaTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = try #require(DateParsing.iso8601("2026-09-11T00:00:00Z"))
    let today = directory.appendingPathComponent("sessions/2026/09/11")
    try FileManager.default.createDirectory(at: today, withIntermediateDirectories: true)
    let unrelated = directory.appendingPathComponent("unrelated.json")
    try quotaFixture("rollout.jsonl").write(to: unrelated)
    try FileManager.default.createSymbolicLink(at: today.appendingPathComponent("rollout-link.jsonl"), withDestinationURL: unrelated)
    let reader = CodexRolloutQuotaReader(directory: directory, now: { now })
    await #expect(throws: QuotaError.notConfigured("未找到 Codex rollout")) { try await reader.fetchQuota() }
}
