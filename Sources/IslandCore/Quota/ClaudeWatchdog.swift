import Foundation

struct ClaudeWatchdogTimeout: Error, Sendable {}

enum ClaudeWatchdog {
    /// Unstructured children are intentional: a cancellation-ignoring dependency must not
    /// hold the caller in a structured task group's implicit join. Late results are discarded.
    static func run<Value: Sendable>(seconds: TimeInterval = 60, clock: any QuotaClock,
                                    onTimeout: @escaping @Sendable () async -> Void,
                                    operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let pair = AsyncStream<Result<Value, any Error>>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let worker = Task {
            do {
                let value = try await operation()
                if !Task.isCancelled { pair.continuation.yield(.success(value)) }
            } catch {
                if !Task.isCancelled { pair.continuation.yield(.failure(error)) }
            }
        }
        let timer = Task {
            do {
                try await clock.sleep(for: seconds)
                try Task.checkCancellation()
                worker.cancel()
                await onTimeout()
                pair.continuation.yield(.failure(ClaudeWatchdogTimeout()))
            } catch { /* Cancellation ends the timer. */ }
        }
        defer { worker.cancel(); timer.cancel(); pair.continuation.finish() }
        var iterator = pair.stream.makeAsyncIterator()
        guard let result = await iterator.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return try result.get()
    }
}
