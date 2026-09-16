import Foundation
import Darwin
import Testing
@testable import IslandCore

/// Transport integration uses only a handwritten shell fixture, never Claude or the keychain.
@Test func ptyFixtureHasTTYAndSizeAndIsReapedAfterKillEscalation() async throws {
    let directory = try quotaTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("fake-interactive")
    try Data("""
    #!/bin/sh
    trap '' TERM
    test -t 0 && test -t 1 && test -t 2 || exit 3
    echo "PID=$$"
    /bin/stty size
    echo "TERM=$TERM"
    test "$#" -eq 3 || exit 4
    test "$1" = '--no-chrome' || exit 5
    test "$2" = '--settings' || exit 6
    test "$3" = '{"remoteControlAtStartup":false}' || exit 7
    echo "ARGS_OK"
    echo "READY"
    while IFS= read -r command; do :; done
    """.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let pty = ClaudePTYProcess()
    let stream = try await pty.start(executable: script, directory: directory)
    let cleanup = Task { try? await Task.sleep(for: .seconds(5)); await pty.finish(graceful: false) }
    var output = ""
    for try await chunk in stream {
        output += String(decoding: chunk, as: UTF8.self)
        if output.contains("READY") { break }
    }
    cleanup.cancel()
    await cleanup.value
    #expect(output.contains("ARGS_OK"))
    #expect(output.contains("40 120"))
    #expect(output.contains("TERM=xterm-256color"))
    let pidLine = try #require(output.components(separatedBy: .newlines).first { $0.hasPrefix("PID=") })
    let pid = try #require(Int32(pidLine.dropFirst(4)))
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
    await #expect(throws: (any Error).self) { try await pty.send("/usage\r") }
    await pty.finish(graceful: false)
}

@Test func ptyGracefulCleanupWritesOnlyUsageEscapeExitAndReaps() async throws {
    let directory = try quotaTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("fake-usage-panel")
    try Data("""
    #!/bin/sh
    /bin/stty raw -echo
    echo "READY"
    /usr/bin/od -An -tx1 -N14 > received-bytes
    """.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let pty = ClaudePTYProcess()
    let stream = try await pty.start(executable: script, directory: directory)
    let watchdog = Task {
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        await pty.finish(graceful: false)
    }
    var output = ""
    for try await chunk in stream {
        output += String(decoding: chunk, as: UTF8.self)
        if output.contains("READY") { break }
    }
    #expect(output.contains("READY"))
    for command in ["\u{1b}", "/exit\r", "\r", "hello\r"] {
        await #expect(throws: (any Error).self) { try await pty.send(command) }
    }
    try await pty.send("/usage\r")
    for command in ["/usage\r", "/exit\r", "hello\r"] {
        await #expect(throws: (any Error).self) { try await pty.send(command) }
    }
    async let first: Void = pty.finish(graceful: true)
    async let second: Void = pty.finish(graceful: true)
    _ = await (first, second)
    watchdog.cancel()
    await watchdog.value
    let received = try String(contentsOf: directory.appendingPathComponent("received-bytes"), encoding: .utf8)
    #expect(received.split(whereSeparator: \.isWhitespace).joined(separator: " ") ==
        "2f 75 73 61 67 65 0d 1b 2f 65 78 69 74 0d")
    await #expect(throws: (any Error).self) { try await pty.send("\u{1b}") }
}
