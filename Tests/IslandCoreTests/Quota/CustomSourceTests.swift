import Foundation
import Darwin
import Testing
@testable import IslandCore
@testable import AgentIsland

private let parserSource = CustomSource(name: "示例", command: "echo 62")
private func parseCustom(_ value: String) throws -> CustomQuotaResult { try CustomQuotaParser.parse(Data(value.utf8), source: parserSource) }

@Test func customFullJSON() throws {
    let result = try parseCustom(#"{"windows":[{"label":"本周","remainingPercent":62,"resetsAt":"2026-01-08T00:00:00Z","periodSeconds":604800},{"label":"余额","valueText":"¥128.50"}],"plan":"Pro","note":"示例说明","future":{"secret":"ignored"}}"#)
    #expect(result.snapshot.windows.count == 2)
    #expect(result.snapshot.windows[0].usedPercent == 38)
    #expect(result.snapshot.windows[0].periodSeconds == 604800)
    #expect(result.snapshot.windows[0].resetsAt != nil)
    #expect(result.snapshot.windows[1].valueText == "¥128.50")
    #expect(result.snapshot.plan == "Pro" && result.snapshot.note == "示例说明")
    #expect(result.warnings.isEmpty)
}
@Test(arguments: ["62", "0", "1", "100", "101", "-4", "1e2"])
func customNumericShortcut(_ value: String) throws {
    let window = try #require(parseCustom(value).snapshot.windows.first)
    #expect(window.label == "示例")
    #expect(window.remainingPercent == min(100, max(0, Double(value) ?? 0)))
}
@Test func customUsedAndClamped() throws {
    let result = try parseCustom(#"{"windows":[{"label":"本月","usedPercent":40},{"label":"低","remainingPercent":-10},{"label":"高","usedPercent":110}]}"#)
    #expect(result.snapshot.windows.map(\.remainingPercent) == [60, 0, 0])
    #expect(result.snapshot.headline?.label == "本月")
}
@Test func customTextTruncatesGraphemesAndMissingLabelWarns() throws {
    let value = String(repeating: "👨‍👩‍👧‍👦", count: 13)
    let result = try parseCustom("{\"windows\":[{\"valueText\":\"\(value)\"}]}")
    #expect(result.snapshot.windows[0].valueText?.count == 12)
    #expect(result.snapshot.windows[0].label == "窗口 1")
    #expect(result.warnings.count == 2)
}
@Test func customFiveWindowsLimitsBeforeInvalidFifth() throws {
    let json = "{\"windows\":[" + Array(repeating: #"{"label":"额度","usedPercent":20}"#, count: 4).joined(separator: ",") + ",null]}"
    let result = try parseCustom(json)
    #expect(result.snapshot.windows.count == 4 && result.warnings.count == 1)
}
@Test(arguments: [#"{"windows":[]}"#, "{}", "[]", "true", "NaN", "Infinity", "1e400",
    #"{"windows":[{"remainingPercent":1e400}]}"#, #"{"windows":[{"remainingPercent":"NaN"}]}"#,
    #"{"windows":[{"remainingPercent":true}]}"#, #"{"windows":[{"label":"x"}]}"#,
    #"{"windows":[{"remainingPercent":50,"valueText":"x"}]}"#])
func customInvalidInputs(_ value: String) {
    #expect(throws: CustomSourceError.self) { try parseCustom(value) }
}
@Test func customInvalidJSONGivesPositionWithoutEcho() {
    do { _ = try parseCustom("{\n\"windows\": [ M12_SECRET ]}") }
    catch let error as CustomSourceError {
        #expect(error.message.contains("行") && error.message.contains("列"))
        #expect(!error.message.contains("M12_SECRET"))
        if case let .invalidJSON(line, column) = error { #expect(line == 2 && column >= 1) }
        else { Issue.record("Expected syntax location") }
    } catch { Issue.record("Unexpected error type") }
}
@Test func customInvalidResetIsIgnored() throws {
    let result = try parseCustom(#"{"windows":[{"label":"额度","usedPercent":2,"resetsAt":"invalid"}]}"#)
    #expect(result.snapshot.windows[0].resetsAt == nil && result.warnings.count == 1)
}

private func fixtureCommand(_ file: String, directory: URL? = nil) throws -> String {
    let url = try #require(Bundle.module.url(forResource: file, withExtension: "zsh", subdirectory: "Fixtures/custom-sources"))
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    return "source " + quote(url.path) + (directory.map { " " + quote($0.path) } ?? "") + " # M12_COMMAND_PRIVATE_MARKER"
}
private func isolatedRunner(_ directory: URL, timeout: Double = 15) -> CustomCommandRunner {
    CustomCommandRunner(timeout: timeout, directory: directory, environment: ["PATH": "/usr/bin:/bin", "ZDOTDIR": directory.path, "HOME": directory.path])
}
private func pid(_ file: String, directory: URL) throws -> pid_t {
    let value = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    return try #require(Int32(value))
}

private func expectProcessReaped(_ pid: pid_t, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    // A killed descendant may remain visible to kill(pid, 0) until macOS reaps it.
    // This bounded polling is fixture-only; production cleanup stays event-driven.
    func isReaped() -> Bool { kill(pid, 0) == -1 && errno == ESRCH }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(15))
    while !isReaped(), clock.now < deadline {
        try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(25))))
    }
    #expect(isReaped(), "Fixture process was not reaped within 15 seconds", sourceLocation: sourceLocation)
}

// Serialize process fixtures; no GPU, network, real profiles, or credential stores are used.
@Suite(.serialized) struct CustomCommandExecutionTests {
    @Test func successfulRealZshAndFailure() async throws {
        let directory = try quotaTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let runner = isolatedRunner(directory)
        let source = CustomSource(name: "示例", command: try fixtureCommand("success"))
        #expect(try await runner.run(source).snapshot.windows.count == 2)
        let failing = CustomSource(name: "失败", command: try fixtureCommand("failure"))
        do { _ = try await runner.run(failing); Issue.record("Expected failure") }
        catch let error as CustomSourceError { #expect(error == .exit(7, "M12_STDERR_PRIVATE_MARKER\n")) }
        #expect(await runner.activeCount == 0)
    }
    @Test func commandNotFoundAndBoundedStderr() async throws {
        let directory = try quotaTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let runner = isolatedRunner(directory)
        do { _ = try await runner.run(.init(name: "missing", command: "m12_nonexistent_command")); Issue.record("Expected failure") }
        catch let error as CustomSourceError { #expect(error.category == "commandNotFound") }
        do { _ = try await runner.run(.init(name: "stderr", command: "/usr/bin/head -c 10000 /dev/zero >&2; exit 5")); Issue.record("Expected failure") }
        catch let error as CustomSourceError {
            if case let .exit(code, text) = error { #expect(code == 5 && text.utf8.count == 512) }
            else { Issue.record("Expected exit failure") }
        }
    }
    @Test func outputLimit() async throws {
        let directory = try quotaTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let runner = isolatedRunner(directory)
        let source = CustomSource(name: "large", command: try fixtureCommand("oversize"))
        await #expect(throws: CustomSourceError.outputTooLarge) { try await runner.run(source) }
    }
    @Test func timeoutKillsParentAndSleepChild() async throws {
        let directory = try quotaTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let runner = isolatedRunner(directory, timeout: 0.4)
        let source = CustomSource(name: "timeout", command: try fixtureCommand("group", directory: directory))
        await #expect(throws: CustomSourceError.timeout) { try await runner.run(source) }
        let parent = try pid("parent.pid", directory: directory), child = try pid("child.pid", directory: directory)
        try await expectProcessReaped(parent)
        try await expectProcessReaped(child)
        #expect(await runner.activeCount == 0)
    }
    @Test func stubbornGroupEscalatesAfterTwoSeconds() async throws {
        let directory = try quotaTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let runner = isolatedRunner(directory, timeout: 0.2)
        let source = CustomSource(name: "stubborn", command: try fixtureCommand("stubborn", directory: directory))
        let start = ContinuousClock.now
        await #expect(throws: CustomSourceError.timeout) { try await runner.run(source) }
        #expect(start.duration(to: .now) >= .seconds(2))
        let parent = try pid("parent.pid", directory: directory)
        try await expectProcessReaped(parent)
    }
    @Test func sameSourceNeverOverlapsAndGlobalLimitIsThree() async throws {
        let directory = try quotaTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let runner = isolatedRunner(directory)
        let source = CustomSource(name: "serial", command: try fixtureCommand("slow"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { _ = try await runner.run(source) } }
            try await group.waitForAll()
        }
        #expect(await runner.peakConcurrency == 1)
        #expect(await runner.starts[source.id] == 4)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<7 {
                let value = CustomSource(name: "parallel \(index)", command: source.command)
                group.addTask { _ = try await runner.run(value) }
            }
            try await group.waitForAll()
        }
        #expect(await runner.peakConcurrency == 3)
        #expect(await runner.activeCount == 0)
    }
    @Test func suspensionCancelsActiveAndQueuedCommands() async throws {
        let directory = try quotaTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let runner = isolatedRunner(directory)
        let source = CustomSource(name: "pause", command: try fixtureCommand("group", directory: directory))
        let first = Task { try await runner.run(source) }
        let second = Task { try await runner.run(source) }
        try await eventually { FileManager.default.fileExists(atPath: directory.appendingPathComponent("child.pid").path) }
        await runner.setSuspended(true)
        for task in [first, second] { await #expect(throws: CancellationError.self) { try await task.value } }
        await #expect(throws: CancellationError.self) { try await runner.run(source) }
        let child = try pid("child.pid", directory: directory)
        try await expectProcessReaped(child)
        #expect(await runner.starts[source.id] == 1)
        await runner.setSuspended(false)
        #expect(try await runner.run(.init(name: "wake", command: "echo 62")).snapshot.windows.first?.remainingPercent == 62)
    }
    @Test func runtimeAddEditDisableDeleteAndLock() async throws {
        let directory = try quotaTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let runner = isolatedRunner(directory)
        let service = QuotaService(providers: [], customRunner: runner)
        var source = CustomSource(name: "dynamic", command: "echo 62", intervalMinutes: 30)
        await service.setCustomSources([source]); await service.setEnabledProviders([source.id]); await service.start()
        try await eventually { await runner.statuses[source.id]?.category == "success" }
        source.command = try fixtureCommand("group", directory: directory)
        await service.setCustomSources([source]); await service.setEnabledProviders([source.id])
        try await eventually { FileManager.default.fileExists(atPath: directory.appendingPathComponent("child.pid").path) }
        let child = try pid("child.pid", directory: directory)
        await service.setEnabledProviders([])
        try await expectProcessReaped(child)
        #expect(await runner.activeCount == 0)
        await service.setSuspended(true)
        source.command = "echo 70"
        await service.setCustomSources([source]); await service.setEnabledProviders([source.id]); await service.refreshNow()
        let before = await runner.starts[source.id]
        await service.setSuspended(false)
        try await eventually { await runner.starts[source.id] == (before ?? 0) + 1 }
        await service.setCustomSources([])
        #expect(await runner.activeCount == 0)
        await service.stop()
    }
    @Test func staleDataAndPrivacy() async throws {
        let directory = try quotaTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let runner = isolatedRunner(directory)
        let logDirectory = directory.appendingPathComponent("diagnostics")
        let diagnostics = ClaudeDiagnostics(directory: logDirectory)
        await diagnostics.record(.wake)
        let source = CustomSource(name: "private fixture", command: try fixtureCommand("sequence", directory: directory))
        let service = QuotaService(providers: [], customRunner: runner, diagnostics: diagnostics)
        await service.setCustomSources([source]); await service.setEnabledProviders([source.id])
        let updates = await service.updates(), log = QuotaUpdateLog()
        let collector = Task { for await value in updates { await log.append(value) } }
        await service.refreshNow()
        try await eventually { await log.values.count == 1 }
        try Data().write(to: directory.appendingPathComponent("fail"))
        await service.refreshNow()
        try await eventually { await log.values.count == 2 }
        let values = await log.values
        #expect(values[0].health == .ok)
        if case .stale = values[1].health {} else { Issue.record("Expected stale data") }
        #expect(values[1].snapshot == values[0].snapshot)
        #expect(values[1].diagnostic?.contains("M12_STDERR_PRIVATE_MARKER") == true)
        let state = ProviderState(descriptor: source.descriptor, detection: .init(installed: [source.id: true]), override: nil, latestClaudeModel: nil)
        let report = String(decoding: try DumpProviders.encoded(states: [state], statuses: await runner.statuses), as: UTF8.self)
        let diagnosticText = String(decoding: try Data(contentsOf: logDirectory.appendingPathComponent("claude.jsonl")), as: UTF8.self)
        let failedDump = await DumpQuota.query(CustomQuotaProvider(source: source, runner: runner))
        let failureText = String(decoding: try JSONEncoder().encode(failedDump), as: UTF8.self)
        let success = CustomSource(name: "success", command: try fixtureCommand("success"))
        let successDump = await DumpQuota.query(CustomQuotaProvider(source: success, runner: runner))
        let successText = String(decoding: try JSONEncoder().encode(successDump), as: UTF8.self)
        for text in [report, diagnosticText, failureText, successText] {
            for marker in ["M12_COMMAND_PRIVATE_MARKER", "M12_STDERR_PRIVATE_MARKER", "M12_STDOUT_PRIVATE_MARKER", source.command] {
                #expect(!text.contains(marker))
            }
        }
        let object = try #require(JSONSerialization.jsonObject(with: Data(report.utf8)) as? [[String: Any]])
        #expect(Set(object[0].keys) == ["id", "name", "enabled", "lastRunAt", "lastStatus"])
        #expect(object[0]["lastStatus"] as? String == "exit")
        #expect(successText.contains("¥128.50"))
        await service.stop(); await collector.value
    }
    @Test func intervalsStaggerManualRefreshAndWake() async throws {
        let directory = try quotaTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let runner = isolatedRunner(directory)
        let clock = FakeQuotaClock()
        let service = QuotaService(providers: [], clock: clock, customRunner: runner)
        let first = CustomSource(name: "minute", command: "echo 62", intervalMinutes: 1)
        let second = CustomSource(name: "half hour", command: "echo 70", intervalMinutes: 30)
        await service.setCustomSources([first, second]); await service.setEnabledProviders([first.id, second.id])
        await service.start()
        try await eventually { clock.sleeps.contains(60) && clock.sleeps.contains(0.25) }
        #expect(await runner.starts[first.id] == 1)
        #expect(await runner.starts[second.id] == nil)
        clock.advance(0.25)
        try await eventually { clock.sleeps.contains(1800) }
        await service.setInterval(30)
        #expect(await runner.starts[first.id] == 1)
        #expect(await runner.starts[second.id] == 1)
        clock.advance(60)
        try await eventually { await runner.starts[first.id] == 2 }
        #expect(await runner.starts[second.id] == 1)
        await service.refreshNow()
        try await eventually { await runner.starts[first.id] == 3 }
        clock.advance(0.25)
        try await eventually { await runner.starts[second.id] == 2 }
        await service.setSuspended(true)
        clock.advance(3600)
        #expect(await runner.starts[first.id] == 3)
        #expect(await runner.starts[second.id] == 2)
        await service.setSuspended(false)
        try await eventually { await runner.starts[first.id] == 4 }
        clock.advance(0.25)
        try await eventually { await runner.starts[second.id] == 3 }
        await service.stop()
    }
    @Test func shutdownAlsoWaitsForSettingsPreviewGroup() async throws {
        let directory = try quotaTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let runner = isolatedRunner(directory)
        let service = QuotaService(providers: [], customRunner: runner)
        let source = CustomSource(name: "preview", command: try fixtureCommand("group", directory: directory))
        let preview = Task { try await runner.run(source) }
        try await eventually { FileManager.default.fileExists(atPath: directory.appendingPathComponent("child.pid").path) }
        let child = try pid("child.pid", directory: directory)
        await service.stop()
        await #expect(throws: CancellationError.self) { try await preview.value }
        try await expectProcessReaped(child)
    }
    @Test func loginProfileAndWorkingDirectoryAreUsed() async throws {
        let directory = try quotaTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        try Data("M12_FIXTURE_PROFILE=62\n".utf8).write(to: directory.appendingPathComponent(".zprofile"))
        let runner = isolatedRunner(directory)
        let source = CustomSource(name: "profile", command: "[[ -f .zprofile ]] || exit 8; print -r -- $M12_FIXTURE_PROFILE")
        #expect(try await runner.run(source).snapshot.windows.first?.remainingPercent == 62)
    }
    @Test func mockServiceCannotRegisterUserCommand() async throws {
        let directory = try quotaTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let runner = isolatedRunner(directory)
        let service = QuotaService(providers: [], customRunner: runner, allowsCustomCommands: false)
        let source = CustomSource(name: "forbidden", command: "exit 99")
        await service.setCustomSources([source]); await service.setEnabledProviders([source.id]); await service.refreshNow(); await service.start()
        #expect(await runner.starts.isEmpty)
        await service.stop()
    }
}
