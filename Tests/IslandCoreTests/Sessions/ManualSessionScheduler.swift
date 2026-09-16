import Foundation
@testable import IslandCore

// The lock protects every mutable field; continuations resume outside the lock.
final class ManualSessionScheduler: SessionScheduler, @unchecked Sendable {
    private struct Waiter {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var waiters: [UUID: Waiter] = [:]
    let sleeps = AsyncStream<ContinuousClock.Instant>.makeStream()

    func now() -> ContinuousClock.Instant { lock.withLock { instant } }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result: Int = lock.withLock {
                    if Task.isCancelled { return 1 }
                    if deadline <= instant { return 2 }
                    waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                    return 0
                }
                if result == 1 { continuation.resume(throwing: CancellationError()) }
                else if result == 2 { continuation.resume() }
                sleeps.continuation.yield(deadline)
            }
        } onCancel: {
            let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let ready = lock.withLock {
            instant = instant.advanced(by: duration)
            let ready = waiters.filter { $0.value.deadline <= instant }
            for id in ready.keys { waiters[id] = nil }
            return Array(ready.values)
        }
        for waiter in ready { waiter.continuation.resume() }
    }

    func waitForSleep(until deadline: ContinuousClock.Instant) async {
        for await value in sleeps.stream {
            if value == deadline { return }
        }
    }
}
