import Foundation
import Darwin
import Testing
@testable import IslandCore
@testable import AgentIsland

@Test func smcABIAndDecoding() {
    #expect(MemoryLayout<SMCParam>.size == 80)
    #expect(MemoryLayout<SMCParam>.stride == 80)
    #expect(MemoryLayout<SMCParam>.offset(of: \.dataSize) == 28)
    #expect(MemoryLayout<SMCParam>.offset(of: \.result) == 40)
    #expect(MemoryLayout<SMCParam>.offset(of: \.command) == 42)
    #expect(MemoryLayout<SMCParam>.offset(of: \.bytes) == 48)
    #expect(SMCValue(type: "flt ", bytes: [0, 0xB0, 0x1C, 0x45]).decoded == 2507)
    #expect(SMCValue(type: "fpe2", bytes: [0x27, 0x2C]).decoded == 2507)
    #expect(SMCValue(type: "ui8 ", bytes: [1]).decoded == 1)
    #expect(SMCValue(type: "ui16", bytes: [0x09, 0xCB]).decoded == 2507)
    #expect(SMCValue(type: "sp78", bytes: [0x19, 0x80]).decoded == 25.5)
    #expect(SMCValue(type: "sp78", bytes: [0xFE, 0x80]).decoded == -1.5)
    #expect(SMCValue(type: "flt ", bytes: [0, 0, 0x80, 0x7F]).decoded == nil)
    for type in ["flt ", "fpe2", "ui8 ", "ui16", "sp78", "????"] {
        #expect(SMCValue(type: type, bytes: []).decoded == nil)
    }
    #expect(SMCValue(type: "????", bytes: [1, 2, 3, 4]).decoded == nil)
}

actor FakeSMC: SMCReading {
    var values: [String: SMCValue]
    var reads = 0
    var resets = 0
    init(_ values: [String: SMCValue] = [:]) { self.values = values }
    func read(key: String) -> SMCValue? { reads += 1; return values[key] }
    func reset() { resets += 1 }
    func set(_ key: String, _ value: SMCValue) { values[key] = value }
    static let valid: [String: SMCValue] = [
        "FNum": .init(type: "ui8 ", bytes: [1]), "F0Ac": .init(type: "ui16", bytes: [0x09, 0xCB]),
        "F0Mn": .init(type: "ui16", bytes: [0x09, 0x0D]), "F0Mx": .init(type: "ui16", bytes: [0x19, 0x96])
    ]
}

@Test func smcFailureIsLatchedUntilReset() async {
    // An unavailable transport models open failure; other fixtures model missing/unknown keys and fanless machines.
    var missing = FakeSMC.valid; missing["F0Ac"] = nil
    var unknown = FakeSMC.valid; unknown["F0Ac"] = .init(type: "????", bytes: [0])
    for values in [[:], missing, unknown, ["FNum": SMCValue(type: "ui8 ", bytes: [0])]] {
        let smc = FakeSMC(values)
        let fan = FanReader(smc: smc)
        #expect(await fan.sample() == nil)
        let count = await smc.reads
        for _ in 0..<4 { #expect(await fan.sample() == nil) }
        #expect(await smc.reads == count)
        await fan.reset()
        #expect(await fan.sample() == nil)
        #expect(await smc.reads > count)
    }
    let smc = FakeSMC(FakeSMC.valid)
    let fan = FanReader(smc: smc)
    #expect(await fan.sample()?.count == 1)
    #expect(await fan.sample()?.fans.first?.rpm == 2507)
    await smc.set("F0Ac", .init(type: "ui16", bytes: [0, 0]))
    #expect(await fan.sample()?.fans.first?.text == "风扇 静止")
}

@Test func networkDifferenceAndWraparound() throws {
    var difference = NetworkDifferencer()
    #expect(difference.rate(for: .init(time: 0, counters: [
        .init(name: "en0", received: UInt64.max - 99, sent: 5_000_000_000),
        .init(name: "en1", received: 0, sent: 0), .init(name: "utun0", received: 10, sent: 10)
    ])) == nil)
    let computed = difference.rate(for: .init(time: 0.5, counters: [
        .init(name: "en0", received: 100, sent: 5_000_000_100), .init(name: "en1", received: 50, sent: 50),
        .init(name: "en2", received: 8_000_000_000, sent: 8_000_000_000),
        .init(name: "utun0", received: 100_000, sent: 100_000)
    ]))
    let rate = try #require(computed)
    #expect(rate.downBytesPerSec == 500)
    #expect(rate.upBytesPerSec == 300)
    #expect(rate.interfaces == ["en0", "en1", "en2"])
    let afterRemoval = difference.rate(for: .init(time: 1.5, counters: [.init(name: "en1", received: 60, sent: 70)]))
    let removed = try #require(afterRemoval)
    #expect(removed.downBytesPerSec == 10)
    #expect(removed.upBytesPerSec == 20)
    #expect(difference.rate(for: .init(time: 1.5, counters: [])) == nil)
    for name in ["lo0", "utun0", "awdl0", "llw0", "bridge0", "anpi0"] { #expect(!NetworkReader.includes(name)) }
    #expect(NetworkReader.includes("en0")); #expect(NetworkReader.includes("en12"))
}

@Test func routingMessagesAreBoundedAndUnaligned() {
    var header = if_msghdr2()
    header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
    header.ifm_version = UInt8(RTM_VERSION); header.ifm_type = UInt8(RTM_IFINFO2); header.ifm_index = 1
    header.ifm_data.ifi_ibytes = 8_000_000_000; header.ifm_data.ifi_obytes = 9_000_000_000
    let valid = withUnsafeBytes(of: header) { Data($0) }
    var data = Data([5, 0, UInt8(RTM_VERSION), 0, 0])
    data.append(valid)
    #expect(NetworkReader.parse(data, nameForIndex: { $0 == 1 ? "en0" : nil }) == [
        .init(name: "en0", received: 8_000_000_000, sent: 9_000_000_000)
    ])
    #expect(NetworkReader.parse(data, nameForIndex: { _ in "utun0" }).isEmpty)
    for size in 0..<valid.count {
        #expect(NetworkReader.parse(Data(valid.prefix(size)), nameForIndex: { _ in "en0" }).isEmpty)
    }
    for bytes: [UInt8] in [[0, 0, 5, 0], [3, 0, 5, 0], [255, 255, 5, 0], [4, 0, 5, UInt8(RTM_IFINFO2)]] {
        #expect(NetworkReader.parse(Data(bytes), nameForIndex: { _ in "en0" }).isEmpty)
    }
}

@Test func memoryFormulaAndSystemFormatting() throws {
    let memory = MemoryMetrics.calculate(internalPages: 60, purgeable: 10, wired: 12, compressed: 10, pageSize: 1024, total: 100 * 1024)
    #expect(memory.usedBytes == 72 * 1024)
    #expect(memory.percent == 72)
    #expect(memory.text == "内存 72%")
    #expect(MemoryMetrics.calculate(internalPages: 0, purgeable: 10, wired: 12, compressed: 10, pageSize: 1, total: 100).usedBytes == 22)
    #expect(MemoryMetrics(usedBytes: 1, totalBytes: 0).percent == 0)
    #expect(MemoryMetrics.calculate(internalPages: .max, purgeable: 0, wired: .max, compressed: .max, pageSize: .max, total: .max).usedBytes == .max)
    #expect(SystemMetricFormat.rate(nil) == "—")
    #expect(SystemMetricFormat.rate(.infinity) == "—")
    #expect(SystemMetricFormat.rate(1023) == "0 KB/s")
    #expect(SystemMetricFormat.rate(1024) == "1.0 KB/s")
    #expect(SystemMetricFormat.rate(2.5 * 1024 * 1024) == "2.5 MB/s")
    #expect(SystemMetricFormat.rate(1.5 * 1024 * 1024 * 1024) == "1.5 GB/s")
    #expect(FanReading(index: 0, rpm: 800, minRPM: 0, maxRPM: 1000).warning)
    #expect(!FanReading(index: 0, rpm: 799, minRPM: 0, maxRPM: 1000).warning)
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(SystemMetrics(memory: memory))) as? [String: Any])
    #expect(json["fan"] is NSNull)
    #expect((json["memory"] as? [String: Any])?["percent"] as? Double == 72)
    #expect(try LaunchOptions(arguments: ["--dump", "system"]).dump == "system")
}

@MainActor @Test func systemSettingsAndWingSafety() {
    let settings = AppSettings(), store = IslandStore()
    #expect(settings.showCPU && settings.showNetwork && settings.showFan && settings.showMemory)
    settings.showCPU = false; settings.showNetwork = false; settings.showFan = false; settings.showMemory = false
    settings.apply(to: store)
    #expect(!store.systemMetricOptions.enabled)
    for hasNotch in [true, false] {
        let notch = SnapshotExporter.metrics(hasNotch: hasNotch)
        let rects = IslandLayout.expandedWingRects(notch: notch)
        let safety: CGFloat = hasNotch ? 6 : 0
        #expect(NSMaxX(rects.left) <= NSMinX(notch.notchRect) - safety)
        #expect(NSMinX(rects.right) >= NSMaxX(notch.notchRect) + safety)
        let frame = IslandLayout.frame(for: .expanded, notch: notch)
        #expect(NSMinX(rects.left) >= NSMinX(frame) + safety)
        #expect(NSMaxX(rects.right) <= NSMaxX(frame) - safety)
    }
}
