import Foundation
import Darwin
import IslandCore

@MainActor enum Measure {
    struct Sample {
        var cpu: Double
        var resident: UInt64
        var peak: Int64
        var bodies: UInt64
        var draws: UInt64
        var layers: UInt64
        @MainActor static func read() -> Sample {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            var task = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            let result = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &task, size)
            let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            return Sample(cpu: cpu, resident: result == size ? task.pti_resident_size : 0, peak: Int64(usage.ru_maxrss),
                          bodies: UIRenderMetrics.bodies, draws: UIRenderMetrics.draws, layers: UIRenderMetrics.layerUpdates)
        }
    }
    struct StateTotals {
        var seconds = 0.0
        var cpu = 0.0
        var peak: UInt64 = 0
        var draws: UInt64 = 0
        var bodies: UInt64 = 0
        var layers: UInt64 = 0
        mutating func add(from previous: Sample, to next: Sample, seconds: Double) {
            self.seconds += seconds
            cpu += next.cpu - previous.cpu
            peak = max(peak, previous.resident, next.resident)
            draws += next.draws - previous.draws
            bodies += next.bodies - previous.bodies
            layers += next.layers - previous.layers
        }
        var json: [String: Any] {
            ["observed": seconds > 0, "sampledSeconds": seconds,
             "averageCPUPercent": seconds > 0 ? cpu / seconds * 100 as Any : NSNull(),
             "peakResidentBytes": peak,
             "uiRedrawsPerSecond": seconds > 0 ? Double(draws) / seconds as Any : NSNull(),
             "rootBodyEvaluationsPerSecond": seconds > 0 ? Double(bodies) / seconds as Any : NSNull(),
             "layerUpdatesPerSecond": seconds > 0 ? Double(layers) / seconds as Any : NSNull()]
        }
    }
    static func elapsed(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Double {
        let duration = from.duration(to: to).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
    static func run(store: IslandStore, quota: QuotaService, sessions: SessionService, presentation: String, realData: Bool = false, seconds: Double) async {
        let started = ContinuousClock.now
        let initial = Sample.read()
        var previous = initial, baseline = initial
        var previousTime = started, baselineTime = started
        var previousWorking = store.anyWorking
        var states: [String: StateTotals] = ["idle": .init(), "active": .init(), "transition": .init()]
        var steady: [String: StateTotals] = states
        var tick = 1.0
        // Sampling exists only in --measure. Normal operation has no measurement timer.
        while elapsed(started, .now) < seconds {
            let deadline = started.advanced(by: .seconds(min(seconds, tick)))
            do { try await ContinuousClock().sleep(until: deadline, tolerance: .milliseconds(10)) } catch { return }
            let now = ContinuousClock.now, next = Sample.read(), working = store.anyWorking
            let state = previousWorking == working ? (working ? "active" : "idle") : "transition"
            let interval = elapsed(previousTime, now)
            states[state, default: .init()].add(from: previous, to: next, seconds: interval)
            if elapsed(started, previousTime) >= 5 {
                steady[state, default: .init()].add(from: previous, to: next, seconds: interval)
            } else { baseline = next; baselineTime = now }
            previous = next; previousTime = now; previousWorking = working
            tick += 1
        }
        let final = previous, duration = elapsed(started, previousTime)
        let quotaCounts = await quota.refreshCounts, sessionCounts = await sessions.refreshCounts
        let sessionMetrics = await sessions.metrics
        let report: [String: Any] = [
            "sessionRescans": sessionMetrics.sessionRescans,
            "sessionRescansSkipped": sessionMetrics.sessionRescansSkipped,
            "parsedBytesTotal": sessionMetrics.parsedBytesTotal,
            "sessionUpdatesPublished": sessionMetrics.updatesPublished,
            "sessionRescanDefinition": "Lifetime provider scans; skipped counts merged or rate-delayed requests. parsedBytesTotal counts transcript/rollout bytes read, including partial and malformed lines. Wake bypasses the normal 500 ms minimum; hidden scans have a 30 s minimum.",
            "glyphBitmapDecodes": UIRenderMetrics.glyphBitmapDecodes,
            "glyphCacheHits": UIRenderMetrics.glyphCacheHits,
            "dataMode": realData ? "real" : "mock",
            "realDataPeakMemoryBytes": realData ? final.peak as Any : NSNull(),
            "firstQuotaMs": store.firstQuotaMs as Any? ?? NSNull(),
            "firstSessionMs": store.firstSessionMs as Any? ?? NSNull(),
            "requestedDurationSeconds": seconds, "durationSeconds": duration, "presentation": presentation,
            "cpuSeconds": final.cpu - initial.cpu, "cpuPercent": (final.cpu - initial.cpu) / max(0.001, duration) * 100,
            "steadyCPUPercent": (final.cpu - baseline.cpu) / max(0.001, elapsed(baselineTime, previousTime)) * 100,
            "peakMemoryBytes": final.peak, "initialResidentBytes": initial.resident,
            "baselineResidentBytesAt5Seconds": baseline.resident, "finalResidentBytes": final.resident,
            "memoryGrowthBytes": Int64(final.resident) - Int64(baseline.resident),
            "coldStartMemoryGrowthBytes": Int64(final.resident) - Int64(initial.resident),
            "states": states.mapValues(\.json), "steadyStatesAfter5Seconds": steady.mapValues(\.json),
            "uiRedrawDefinition": "NSHostingView.draw calls; root body evaluations and native layer rebuilds reported separately. Compositor keyframes are not CPU redraws and are capped at 10 Hz per layer.",
            "stateSampling": "1 second; intervals spanning a working-state change are reported as transition; unobserved states have null averages",
            "quotaRefreshCounts": Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0.rawValue, quotaCounts[$0, default: 0]) }),
            "sessionRefreshCounts": Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0.rawValue, sessionCounts[$0, default: 0]) })
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    }
    static func headless(options: LaunchOptions) async {
        let runtime = RuntimeData(options: options)
        let quota = runtime.quota, sessions = runtime.sessions, store = runtime.store
        let starting = Task {
            await store.configure(interval: 60, activeWindow: 1800)
            await store.start()
        }
        await run(store: store, quota: quota, sessions: sessions, presentation: "headless", realData: options.mockScenario == nil, seconds: options.exitAfter ?? 60)
        starting.cancel()
        await starting.value
        await store.stop()
    }
}
