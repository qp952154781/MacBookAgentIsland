import Foundation

/// Shared by scheduled refreshes, manual refreshes, and the settings preview.
/// A slot remains occupied until process-group cleanup completes.
public actor CustomCommandRunner {
    public static let shared = CustomCommandRunner()
    private struct Request {
        let token: UUID
        let source: CustomSource
        let continuation: CheckedContinuation<CustomQuotaResult, any Error>
    }
    private var queue: [Request] = []
    private var active: [UUID: (ProviderID, Task<Void, Never>)] = [:]
    private var suspended = false
    private var suspensionVersion = 0
    private let timeout: TimeInterval
    private let directory: URL
    private let environment: [String: String]?
    public private(set) var statuses: [ProviderID: CustomRunStatus] = [:]
    public private(set) var previews: [ProviderID: CustomQuotaResult] = [:]
    public private(set) var peakConcurrency = 0
    public private(set) var starts: [ProviderID: Int] = [:]
    public var activeCount: Int { active.count }

    public init(timeout: TimeInterval = 15, directory: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String]? = nil) {
        self.timeout = timeout; self.directory = directory; self.environment = environment
    }
    public func run(_ source: CustomSource) async throws -> CustomQuotaResult {
        let token = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !suspended else { throw CancellationError() }
            return try await withCheckedThrowingContinuation { continuation in
                queue.append(.init(token: token, source: source, continuation: continuation))
                pump()
            }
        } onCancel: { Task { await self.cancel(token) } }
    }
    private func pump() {
        guard !suspended else { return }
        while active.count < 3, let index = queue.firstIndex(where: { request in !active.values.contains { $0.0 == request.source.id } }) {
            let request = queue.remove(at: index)
            let task = Task { [timeout, directory, environment] in
                let result: Result<CustomQuotaResult, any Error>
                do {
                    try Task.checkCancellation()
                    let output = try await CustomCommandProcess.run(command: request.source.command, timeout: timeout,
                                                                   directory: directory, environment: environment)
                    guard output.exitCode == 0 else { throw CustomSourceError.exit(output.exitCode, output.stderr) }
                    result = .success(try CustomQuotaParser.parse(output.stdout, source: request.source))
                } catch { result = .failure(error) }
                finish(request, result: result)
            }
            active[request.token] = (request.source.id, task)
            starts[request.source.id, default: 0] += 1
            peakConcurrency = max(peakConcurrency, active.count)
        }
    }
    private func finish(_ request: Request, result: Result<CustomQuotaResult, any Error>) {
        active[request.token] = nil
        switch result {
        case .success(let parsed):
            statuses[request.source.id] = .init(time: Date(), category: "success")
            previews[request.source.id] = parsed
        case .failure(let error):
            statuses[request.source.id] = .init(time: Date(), category: error is CancellationError ? "cancelled" : (error as? CustomSourceError)?.category ?? "launch")
        }
        request.continuation.resume(with: result)
        pump()
    }
    private func cancel(_ token: UUID) {
        if let index = queue.firstIndex(where: { $0.token == token }) {
            queue.remove(at: index).continuation.resume(throwing: CancellationError())
        }
        active[token]?.1.cancel()
    }
    public func cancel(source id: ProviderID) async {
        for request in queue.filter({ $0.source.id == id }) { cancel(request.token) }
        let tasks = active.values.filter { $0.0 == id }.map(\.1)
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
    }
    public func cancelAll() async {
        let wasSuspended = suspended, version = suspensionVersion + 1
        await setSuspended(true)
        if suspensionVersion == version { suspended = wasSuspended }
    }
    public func forget(_ id: ProviderID) { statuses[id] = nil; previews[id] = nil }
    public func setSuspended(_ value: Bool) async {
        suspended = value; suspensionVersion += 1
        if value {
            for request in queue { request.continuation.resume(throwing: CancellationError()) }
            queue.removeAll()
            let tasks = active.values.map(\.1)
            tasks.forEach { $0.cancel() }
            for task in tasks { await task.value }
        } else { pump() }
    }
}

public struct CustomQuotaProvider: QuotaProviding {
    public let source: CustomSource
    public let runner: CustomCommandRunner
    public var agent: ProviderID { source.id }
    public init(source: CustomSource, runner: CustomCommandRunner = .shared) { self.source = source; self.runner = runner }
    public func fetchQuota() async throws -> QuotaSnapshot { try await runner.run(source).snapshot }
}
