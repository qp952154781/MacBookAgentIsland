import Foundation
import Testing
@testable import IslandCore

private actor TemperatureProvider: SystemMetricsProviding {
    var calls = 0
    func cpuTemperature() -> CPUTemperatureMetrics? {
        calls += 1
        return .init(averageCelsius: 58, maximumCelsius: 60, keys: ["Tp01"])
    }
    func gpu() -> GPUMetrics? { nil }
    func cpu() -> CPUCounter? { nil }
    func network() -> [NetworkCounter]? { nil }
    func memory() -> MemoryMetrics? { nil }
    func fan() -> FanMetrics? { nil }
    func reset() {}
}

@MainActor private final class TemperatureDefaults: AppSettingsDefaults {
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private actor TemperatureSMC: SMCReading, SMCKeyEnumerating {
    var names: [String]
    var values: [String: SMCValue]
    var enumerations = 0
    var indexedReads = 0
    var valueReads = 0
    var resets = 0
    init(names: [String], values: [String: SMCValue]) {
        self.names = names; self.values = values
    }
    func keyCount() -> Int? { enumerations += 1; return names.count }
    func key(at index: Int) -> String? { indexedReads += 1; return names[index] }
    func read(key: String) -> SMCValue? { valueReads += 1; return values[key] }
    func reset() { resets += 1 }
    func set(_ key: String, _ value: SMCValue?) { values[key] = value }
    func replace(names: [String], values: [String: SMCValue]) {
        self.names = names; self.values = values
    }
}

private func floatValue(_ temperature: Float) -> SMCValue {
    let bits = temperature.bitPattern
    return .init(type: "flt ", bytes: (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
}

private func intelValue(_ temperature: Double) -> SMCValue {
    let bits = UInt16(bitPattern: Int16((temperature * 256).rounded()))
    return .init(type: "sp78", bytes: [UInt8(bits >> 8), UInt8(truncatingIfNeeded: bits)])
}

@Test func temperatureDiscoveryUsesCPUFamiliesAcrossSiliconGenerations() async {
    for (names, expected): ([String], [String]) in [
        (["Tp01", "Tp0A", "Te01", "TfC0", "TCMb", "TVC0", "TVD0", "Tp#1", "Tp02"]
            + (0..<80).map { String(format: "Tg%02d", $0) }
            + (0..<20).map { String(format: "Ts%02d", $0) },
         ["Tp01", "Tp0A", "Te01", "TfC0"]),
        (["Te01", "Te02", "TfC0", "Tg01"], ["Te01", "Te02", "TfC0"]),
        (["Tp01", "Tp02"], ["Tp01", "Tp02"]),
        (["Tg01", "TCMb", "TVC0"], [])
    ] {
        var values = Dictionary(uniqueKeysWithValues: names.map { ($0, floatValue(60)) })
        if names.count > 10 { values["Tp02"] = floatValue(131) } // Reject implausible discovery readings.
        values["TfC0"] = .init(type: "sp78", bytes: [0x3c, 0]) // Reject non-float types.
        if expected.contains("TfC0") { values["TfC0"] = floatValue(70) }
        let smc = TemperatureSMC(names: names, values: values)
        let reader = CPUTemperatureReader(smc: smc, platform: .appleSilicon)
        let first = await reader.sample()?.keys
        #expect((first ?? []) == expected, "\(names) selected \(first ?? [])")
        #expect((await reader.sample()?.keys ?? []) == expected)
        #expect(await smc.enumerations == 1)
        #expect(await smc.indexedReads == names.count)
    }
}

@Test func temperatureIntelUsesFirstValidPreferredKey() async {
    let smc = TemperatureSMC(names: [], values: ["TC0D": intelValue(64), "TC0P": intelValue(70)])
    let reader = CPUTemperatureReader(smc: smc, platform: .intel)
    #expect(await reader.sample()?.keys == ["TC0D"])
    #expect(await reader.sample()?.text == "64°C")
    #expect(await smc.enumerations == 0)
    let fallback = CPUTemperatureReader(smc: TemperatureSMC(names: [], values: ["TC0P": intelValue(63)]),
                                        platform: .intel)
    #expect(await fallback.sample()?.keys == ["TC0P"])
    let empty = CPUTemperatureReader(smc: TemperatureSMC(names: [], values: [:]), platform: .intel)
    #expect(await empty.sample() == nil)
}

@Test func temperatureSamplingAveragesAvailableKeysAndRediscoversAfterReset() async {
    let smc = TemperatureSMC(names: ["Tp01", "Te01", "TfC0"], values: [
        "Tp01": floatValue(60), "Te01": floatValue(65), "TfC0": floatValue(70)
    ])
    let reader = CPUTemperatureReader(smc: smc, platform: .appleSilicon)
    let first = await reader.sample()
    #expect(first?.averageCelsius == 65)
    #expect(first?.maximumCelsius == 70)
    #expect(first?.sensorCount == 3)
    #expect(first?.text == "65°C")
    await reader.reset()
    #expect(await reader.sample()?.keys == ["Tp01", "Te01", "TfC0"])
    #expect(await smc.enumerations == 1)
    await smc.set("Te01", nil)
    #expect(await reader.sample()?.averageCelsius == 65)
    #expect(await reader.sample()?.keys == ["Tp01", "TfC0"])
    await smc.set("Tp01", nil)
    await smc.set("TfC0", nil)
    #expect(await reader.sample() == nil)
    #expect(await reader.sample() == nil)
    #expect(await smc.enumerations == 1)
    await smc.replace(names: ["Tp09"], values: ["Tp09": floatValue(58)])
    await reader.reset()
    #expect(await reader.sample()?.keys == ["Tp09"])
    #expect(await smc.enumerations == 2)
    #expect(await smc.resets == 2)
}

@Test func temperatureDumpIncludesMeanMaximumCountAndKeys() throws {
    let metrics = SystemMetrics(cpuTemperature: .init(averageCelsius: 61.5, maximumCelsius: 70,
                                                       keys: ["Tp01", "Te01"]))
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(metrics)) as? [String: Any])
    let temperature = try #require(json["cpuTemperature"] as? [String: Any])
    #expect(temperature["averageCelsius"] as? Double == 61.5)
    #expect(temperature["maximumCelsius"] as? Double == 70)
    #expect(temperature["sensorCount"] as? Int == 2)
    #expect(temperature["keys"] as? [String] == ["Tp01", "Te01"])
}

@Test func smcReadGateRejectsOtherKeysAndEveryWriteCommand() {
    for key in ["FNum", "F0Ac", "F9Mn", "#KEY", "Tp01", "Te01", "TfC0", "TC0P", "TVC0"] {
        #expect(SMCReadGate.allowsKey(key))
        let code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(SMCReadGate.allows(command: 5, key: code))
        #expect(SMCReadGate.allows(command: 9, key: code))
        for command: UInt8 in [0, 1, 2, 3, 4, 6, 7, 10, 11, 255] {
            #expect(!SMCReadGate.allows(command: command, key: code))
        }
    }
    for key in ["OSK0", "FS! ", "F0Tg", "F10Ac", "T ab", "Tp#1", "Tp000", ""] {
        #expect(!SMCReadGate.allowsKey(key))
    }
    #expect(SMCReadGate.allows(command: 8, key: 0))
    #expect(!SMCReadGate.allows(command: 8, key: 0x54703031))
    #expect(!SMCReadGate.allows(command: 5, key: 0))
}

@MainActor @Test func temperatureSettingDefaultsOnAndPersists() {
    let defaults = TemperatureDefaults()
    let settings = AppSettings(defaults: defaults)
    let store = IslandStore()
    #expect(settings.showCPUTemperature)
    settings.showCPUTemperature = false
    settings.apply(to: store)
    #expect(!store.systemMetricOptions.cpuTemperature)
    #expect(!AppSettings(defaults: defaults).showCPUTemperature)
    settings.showCPUTemperature = true
    #expect(AppSettings(defaults: defaults).showCPUTemperature)
}

@MainActor @Test func temperatureSamplingStopsWhenCollapsed() async {
    let provider = TemperatureProvider(), scheduler = ManualSystemScheduler()
    var latest = SystemMetrics()
    let monitor = SystemMetricsMonitor(provider: provider, scheduler: scheduler) { latest = $0 }
    let options = SystemMetricOptions(network: false, fan: false, memory: false, cpu: false,
                                      cpuTemperature: true, gpu: false)
    monitor.update(expanded: false, options: options)
    #expect(await provider.calls == 0)
    monitor.update(expanded: true, options: options)
    await scheduler.waitForDeadlines([2])
    #expect(latest.cpuTemperature?.text == "58°C")
    #expect(await provider.calls == 1)
    await scheduler.advance(to: 2)
    await scheduler.waitForDeadlines([4])
    #expect(await provider.calls == 2)
    monitor.update(expanded: false, options: options)
    await scheduler.waitForDeadlines([])
    await scheduler.advance(to: 20)
    #expect(await provider.calls == 2)
    monitor.stop()
}
