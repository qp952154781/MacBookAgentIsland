import Foundation
import Testing
@testable import IslandCore

@Test func durationFormattingBoundaries() {
    for (seconds, text) in [(0.0, "刚刚"), (-1, "刚刚"), (59, "刚刚"), (60, "1 分钟"),
                            (3599, "59 分钟"), (3600, "1小时0分"), (3660, "1小时1分"),
                            (86399, "23小时59分"), (86400, "1天0小时")] {
        #expect(DisplayTime.duration(seconds) == text)
    }
    #expect(DisplayTime.duration(.infinity) == "--")
    #expect(DisplayTime.duration(.nan) == "--")
}
@Test func resetAndAbsoluteFormatting() throws {
    let now = try #require(DateParsing.iso8601("2026-09-11T10:00:00Z"))
    let zone = try #require(TimeZone(secondsFromGMT: 0))
    #expect(DisplayTime.reset(nil, now: now) == "--")
    #expect(DisplayTime.reset(now, now: now) == "—")
    #expect(DisplayTime.reset(now.addingTimeInterval(-1200), now: now) == "—")
    #expect(DisplayTime.resetHelp(now.addingTimeInterval(-1200), now: now) == "服务端未提供新的重置时间")
    #expect(DisplayTime.resetHelp(now, now: now) == "服务端未提供新的重置时间")
    #expect(DisplayTime.resetHelp(nil, now: now) == "服务端未提供重置时间")
    #expect(DisplayTime.resetHelp(now.addingTimeInterval(60), now: now, timeZone: zone) == "重置于 2026-09-11 10:01")
    #expect(DisplayTime.reset(now.addingTimeInterval(59), now: now) == "<1m")
    #expect(DisplayTime.reset(now.addingTimeInterval(7980), now: now) == "2h13m")
    #expect(DisplayTime.reset(now.addingTimeInterval(86399), now: now) == "23h59m")
    #expect(DisplayTime.reset(now.addingTimeInterval(86400), now: now, timeZone: zone) == "周六 10:00")
    #expect(DisplayTime.clock(now, timeZone: zone) == "10:00")
    #expect(DisplayTime.full(now, timeZone: zone) == "2026-09-11 10:00")
}
