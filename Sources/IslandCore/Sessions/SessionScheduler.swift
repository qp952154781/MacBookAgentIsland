import Foundation

/// Monotonic deadlines are separate from the wall clock used to interpret session data.
protocol SessionScheduler: Sendable {
    func now() -> ContinuousClock.Instant
    func sleep(until deadline: ContinuousClock.Instant) async throws
}

struct SystemSessionScheduler: SessionScheduler {
    func now() -> ContinuousClock.Instant { .now }
    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await ContinuousClock().sleep(until: deadline, tolerance: .milliseconds(10))
    }
}
