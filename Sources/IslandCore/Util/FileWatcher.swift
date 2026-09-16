import Foundation
import Dispatch
import CoreServices

/// One consumer per watcher. Retain the watcher while consuming `changes`; cancel or release to stop.
public final class FileWatcher: Sendable {
    public let changes: AsyncStream<Set<String>>
    private let state: State

    /// Coalesces changes until quiet, with a maximum wait measured from the first undelivered event.
    public init(paths: [String], debounceInterval: TimeInterval = 0.25, maxInterval: TimeInterval = 1) {
        let pair = AsyncStream<Set<String>>.makeStream()
        changes = pair.stream
        state = State(continuation: pair.continuation, debounceInterval: debounceInterval, maxInterval: maxInterval)
        pair.continuation.onTermination = { [weak state] _ in state?.stop() }
        state.start(paths: paths)
    }

    public func cancel() { state.stop() }
    deinit { state.stop() }

    // FSEvents exposes an opaque context pointer. All mutable state and stream lifecycle operations
    // are confined to `queue`; stop synchronizes with callbacks before the owner releases this box.
    final class State: @unchecked Sendable {
        let queue = DispatchQueue(label: "org.agentisland.AgentIsland.FileWatcher")
        let queueKey = DispatchSpecificKey<Bool>()
        let continuation: AsyncStream<Set<String>>.Continuation
        let debounceInterval: TimeInterval
        let maxInterval: TimeInterval
        let now: @Sendable () -> DispatchTime
        let schedule: (@Sendable (DispatchTime, DispatchWorkItem) -> Void)?
        var stream: FSEventStreamRef?
        var pending: Set<String> = []
        var delivery: DispatchWorkItem?
        var deliveryDeadline: DispatchTime?
        var stopped = false
        var roots: Set<String> = []

        init(continuation: AsyncStream<Set<String>>.Continuation, debounceInterval: TimeInterval,
             maxInterval: TimeInterval = 1,
             now: @escaping @Sendable () -> DispatchTime = { .now() },
             schedule: (@Sendable (DispatchTime, DispatchWorkItem) -> Void)? = nil) {
            self.now = now; self.schedule = schedule
            self.continuation = continuation
            self.debounceInterval = max(0, debounceInterval)
            self.maxInterval = max(0, maxInterval)
            queue.setSpecific(key: queueKey, value: true)
        }

        func start(paths: [String]) {
            queue.sync {
                guard !paths.isEmpty else { stopOnQueue(); return }
                roots = Set(paths.map(physicalPath))
                var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                                   retain: nil, release: nil, copyDescription: nil)
                let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents |
                    kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
                stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
                    guard let info else { return }
                    let state = Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
                    let values = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
                    let recovery = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs |
                        kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
                        kFSEventStreamEventFlagRootChanged)
                    let needsRecovery = (0..<count).contains { flags[$0] & recovery != 0 }
                    // Preserve physical event paths; normalization belongs after coalescing.
                    state.receive(needsRecovery ? state.roots : Set(values.compactMap { $0 as? String }))
                }, &context, Array(roots) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags)
                guard let stream else { stopOnQueue(); return }
                FSEventStreamSetDispatchQueue(stream, queue)
                if !FSEventStreamStart(stream) { stopOnQueue() }
            }
        }

        func receive(_ paths: Set<String>) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard !stopped, !paths.isEmpty else { return }
            pending.formUnion(paths)
            let now = now()
            // Keep the first event's monotonic deadline even while later events reset the debounce.
            let deadline = deliveryDeadline ?? (now + maxInterval)
            deliveryDeadline = deadline
            delivery?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.stopped else { return }
                self.continuation.yield(self.pending)
                self.pending.removeAll()
                self.delivery = nil
                self.deliveryDeadline = nil
            }
            delivery = item
            let scheduledDeadline = min(now + debounceInterval, deadline)
            if let schedule { schedule(scheduledDeadline, item) }
            else { queue.asyncAfter(deadline: scheduledDeadline, execute: item) }
        }

        func stop() {
            if DispatchQueue.getSpecific(key: queueKey) == true { stopOnQueue() }
            else { queue.sync { stopOnQueue() } }
        }

        func stopOnQueue() {
            guard !stopped else { return }
            stopped = true
            delivery?.cancel()
            delivery = nil
            deliveryDeadline = nil
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
            pending.removeAll()
            continuation.finish()
        }
    }
}
