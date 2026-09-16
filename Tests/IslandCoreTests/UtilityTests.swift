import Foundation
import Testing
@testable import IslandCore

private func testDirectory() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent(".build/test-data/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func append(_ text: String, to url: URL) throws {
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.seekToEnd()
    try file.write(contentsOf: Data(text.utf8))
}

@Test func tailAppendPartialAndTruncation() async throws {
    let dir = try testDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("test.jsonl")
    try Data("{\"a\":1}\n".utf8).write(to: url)
    let tailer = JSONLTailer(url: url)
    #expect(await tailer.readNewLines() == [Data("{\"a\":1}".utf8)])
    #expect(await tailer.readNewLines().isEmpty)
    try append("{\"b\":", to: url)
    #expect(await tailer.readNewLines().isEmpty)
    try append("2}\r\nbroken\n{\"c\":3}\n", to: url)
    #expect(await tailer.readNewLines() == [Data("{\"b\":2}".utf8), Data("broken".utf8), Data("{\"c\":3}".utf8)])
    let file = try FileHandle(forWritingTo: url)
    try file.truncate(atOffset: 0)
    try file.write(contentsOf: Data("new\n".utf8))
    try file.close()
    #expect(await tailer.readNewLines() == [Data("new".utf8)])
    try Data("replacement\n".utf8).write(to: url, options: .atomic)
    #expect(await tailer.readNewLines() == [Data("replacement".utf8)])
}

@Test func tailOnlyFinalBytesAndMissingFile() async throws {
    let dir = try testDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("tail.jsonl")
    let missing = JSONLTailer(url: url)
    #expect(await missing.readNewLines().isEmpty)
    try Data("first\nsecond\nlast\n".utf8).write(to: url)
    let tailer = JSONLTailer(url: url, initialTailBytes: 8)
    #expect(await tailer.readNewLines() == [Data("last".utf8)])
    let boundary = JSONLTailer(url: url, initialTailBytes: 5)
    #expect(await boundary.readNewLines() == [Data("last".utf8)])
    let zero = JSONLTailer(url: url, initialTailBytes: 0)
    #expect(await zero.readNewLines().isEmpty)
    try append("next\n", to: url)
    #expect(await zero.readNewLines() == [Data("next".utf8)])
    #expect(await missing.readNewLines().count == 4)
}

@Test func tailUTF8AndFixture() async throws {
    let dir = try testDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("unicode.jsonl")
    let bytes = Data("中文\n".utf8)
    try bytes.prefix(2).write(to: url)
    let tailer = JSONLTailer(url: url)
    #expect(await tailer.readNewLines().isEmpty)
    let file = try FileHandle(forWritingTo: url)
    try file.seekToEnd()
    try file.write(contentsOf: bytes.dropFirst(2))
    try file.close()
    #expect(await tailer.readNewLines() == [Data("中文".utf8)])
    let fixture = try #require(Bundle.module.url(forResource: "sample", withExtension: "jsonl", subdirectory: "Fixtures"))
    #expect(await JSONLTailer(url: fixture).readNewLines().count == 2)
}

@Test func tailLimitsReplacementAndTruncation() async throws {
    let dir = try testDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("large.jsonl")
    func contents(repetitions: Int, marker: String) -> Data {
        Data((String(repeating: "{\"fixture\":true}\n", count: repetitions)
              + String(repeating: "x", count: 100) + "\n" + marker + "\n").utf8)
    }
    try contents(repetitions: 150_000, marker: "original").write(to: url)
    let originalInode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
    let tailer = JSONLTailer(url: url, initialTailBytes: 64)
    #expect(await tailer.readNewLines() == [Data("original".utf8)])
    // Retain an incomplete old line to ensure reset also discards the previous buffer.
    try append("unfinished", to: url)
    #expect(await tailer.readNewLines().isEmpty)
    try contents(repetitions: 100_000, marker: "replacement").write(to: url, options: .atomic)
    let replacementInode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
    #expect(try #require(originalInode) != #require(replacementInode))
    #expect(await tailer.readNewLines() == [Data("replacement".utf8)])
    #expect(await tailer.readNewLines().isEmpty)
    let file = try FileHandle(forWritingTo: url)
    try file.truncate(atOffset: 0)
    try file.write(contentsOf: contents(repetitions: 50_000, marker: "truncated"))
    try file.close()
    let truncatedInode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
    #expect(truncatedInode == replacementInode)
    #expect(await tailer.readNewLines() == [Data("truncated".utf8)])
    try append("next\n", to: url)
    #expect(await tailer.readNewLines() == [Data("next".utf8)])
}

@Test func tailScansManyLinesAndChunkBoundaries() async throws {
    let dir = try testDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("chunks.jsonl")
    let longLine = String(repeating: "x", count: 150_000)
    let shortLines = (0..<10_000).map { "{\"row\":\($0)}" }
    let text = longLine + "\r\n\n" + shortLines.joined(separator: "\r\n\n") + "\r\npartial"
    try Data(text.utf8).write(to: url)
    let tailer = JSONLTailer(url: url)
    #expect(await tailer.readNewLines() == ([longLine] + shortLines).map { Data($0.utf8) })
    #expect(await tailer.readNewLines().isEmpty)
    try append(" end\n", to: url)
    #expect(await tailer.readNewLines() == [Data("partial end".utf8)])
}

@Test func dateFormats() throws {
    let base = try #require(DateParsing.iso8601("2026-09-12T03:00:00Z"))
    for suffix in [".123Z", ".123+00:00", ".123456Z", ".123456+00:00"] {
        let date = try #require(DateParsing.iso8601("2026-09-12T03:00:00" + suffix))
        #expect(abs(date.timeIntervalSince(base) - (suffix.contains("456") ? 0.123456 : 0.123)) < 0.000002)
    }
    #expect(DateParsing.iso8601("2026-09-12T04:00:00+01:00") == base)
    #expect(DateParsing.iso8601("invalid") == nil)
    #expect(DateParsing.unixSeconds(1000) == DateParsing.unixMilliseconds(1000000))
    #expect(DateParsing.unixSeconds(.infinity) == nil)
}

@Test func semanticVersions() {
    #expect(ExecutableLocator.compareVersions("2.1.266", "2.1.99") == .orderedDescending)
    #expect(ExecutableLocator.compareVersions("2.10.0", "2.9.99") == .orderedDescending)
    #expect(ExecutableLocator.compareVersions("2.1", "2.1.0") == .orderedSame)
    #expect(ExecutableLocator.compareVersions("2.1.0", "2.1.0-beta.2") == .orderedDescending)
    #expect(ExecutableLocator.compareVersions("2.1.0-beta.11", "2.1.0-beta.2") == .orderedDescending)
    #expect(ExecutableLocator.compareVersions("2.1.0-alpha", "2.1.0-beta") == .orderedAscending)
    #expect(ExecutableLocator.compareVersions("2.1.0+build1", "2.1.0+build2") == .orderedSame)
}

@Test func processOutputAndExit() async throws {
    let output = try await ProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                              arguments: ["-c", "printf 'fixture-output'; printf 'discarded' >&2; exit 7"])
    #expect(output.stdout == Data("fixture-output".utf8))
    #expect(output.exitCode == 7)
    let large = try await ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/head"),
                                           arguments: ["-c", "131072", "/dev/zero"])
    #expect(large.stdout.count == 131072)
}

@Test func processTimeoutCancellationAndLimit() async throws {
    await #expect(throws: ProcessRunnerError.timedOut) {
        try await ProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.05)
    }
    let task = Task { try await ProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"]) }
    try await Task.sleep(for: .milliseconds(30))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    await #expect(throws: ProcessRunnerError.outputLimitExceeded) {
        try await ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-c", "1000", "/dev/zero"], maxOutputBytes: 10)
    }
}

@Test func watcherCancellationClosesStream() async throws {
    let dir = try testDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let watcher = FileWatcher(paths: [dir.path])
    watcher.cancel()
    watcher.cancel()
    var iterator = watcher.changes.makeAsyncIterator()
    #expect(await iterator.next() == nil)
}

// Enable outside the Codex sandbox, which denies starting the system FSEvents stream.
@Test(.enabled(if: ProcessInfo.processInfo.environment["AGENT_ISLAND_FSEVENTS_TEST"] == "1"))
func watcherDeliversChangedPaths() async throws {
    let dir = try testDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let watcher = FileWatcher(paths: [dir.path], debounceInterval: 0.1)
    defer { watcher.cancel() }
    let result = try await withThrowingTaskGroup(of: Set<String>?.self) { group in
        group.addTask {
            for await paths in watcher.changes {
                if paths.contains(where: { $0.hasSuffix("first.txt") }) && paths.contains(where: { $0.hasSuffix("second.txt") }) {
                    return paths
                }
            }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            watcher.cancel()
            return nil
        }
        try Data("one".utf8).write(to: dir.appendingPathComponent("first.txt"))
        try Data("two".utf8).write(to: dir.appendingPathComponent("second.txt"))
        let first = try await group.next()
        group.cancelAll()
        watcher.cancel()
        return first ?? nil
    }
    #expect(result != nil)
}

@Test func watcherDebouncesAndUnionsPaths() async throws {
    let pair = AsyncStream<Set<String>>.makeStream()
    let state = FileWatcher.State(continuation: pair.continuation, debounceInterval: 0.03)
    defer { state.stop() }
    state.queue.async {
        state.receive(["/fixture/first.jsonl"])
        state.receive(["/fixture/second.jsonl", "/fixture/first.jsonl"])
    }
    var iterator = pair.stream.makeAsyncIterator()
    #expect(await iterator.next() == ["/fixture/first.jsonl", "/fixture/second.jsonl"])
    state.queue.async { state.receive(["/fixture/cancelled.jsonl"]) }
    state.stop()
    #expect(await iterator.next() == nil)
}

// Every mutable field is protected by lock. Work items are performed on the watcher's queue.
private final class ManualWatcherSchedule: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = DispatchTime(uptimeNanoseconds: 0)
    private var items: [(DispatchTime, DispatchWorkItem)] = []
    func now() -> DispatchTime { lock.withLock { instant } }
    func schedule(_ deadline: DispatchTime, _ item: DispatchWorkItem) {
        lock.withLock { items.append((deadline, item)) }
    }
    func advance(milliseconds: Int, on queue: DispatchQueue) {
        let ready = lock.withLock {
            instant = instant + .milliseconds(milliseconds)
            let ready = items.filter { $0.0 <= instant }
            items.removeAll { $0.0 <= instant }
            return ready.map { $0.1 }
        }
        queue.sync { for item in ready where !item.isCancelled { item.perform() } }
    }
}

@Test func watcherDeliversDuringContinuousEvents() async {
    let pair = AsyncStream<Set<String>>.makeStream()
    let scheduler = ManualWatcherSchedule()
    let state = FileWatcher.State(continuation: pair.continuation, debounceInterval: 0.25,
                                  now: { scheduler.now() }, schedule: { scheduler.schedule($0, $1) })
    defer { state.stop() }
    state.queue.sync { state.receive(["/fixture/first.jsonl"]) }
    for _ in 0..<19 {
        scheduler.advance(milliseconds: 50, on: state.queue)
        state.queue.sync { state.receive(["/fixture/appending.jsonl"]) }
    }
    scheduler.advance(milliseconds: 49, on: state.queue)
    state.queue.sync { #expect(!state.pending.isEmpty) }
    scheduler.advance(milliseconds: 1, on: state.queue)
    state.queue.sync { #expect(state.pending.isEmpty) }
    var iterator = pair.stream.makeAsyncIterator()
    #expect(await iterator.next() == ["/fixture/first.jsonl", "/fixture/appending.jsonl"])
}
