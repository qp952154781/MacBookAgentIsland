import Foundation

public protocol JSONRPCTransport: Sendable {
    func start(executableURL: URL) async throws -> AsyncThrowingStream<Data, any Error>
    func send(_ data: Data) async throws
    /// Idempotent; also interrupts a pending start/read/write on cancellation.
    func close()
}

public final class StdioJSONRPCTransport: JSONRPCTransport {
    private let process = QuotaProcess()
    public init() {}
    public func start(executableURL: URL) async throws -> AsyncThrowingStream<Data, any Error> {
        process.start(executableURL: executableURL, arguments: ["app-server"], timeout: 15)
    }
    public func send(_ data: Data) async throws { try await process.send(data) }
    public func close() { process.close() }
    deinit { process.close() }
}

struct JSONRPCLineFramer {
    private var pending = Data()
    mutating func append(_ data: Data) throws -> [Data] {
        pending.append(data)
        guard pending.count <= 2 * 1024 * 1024 else { throw QuotaError.decoding("额度响应行过长") }
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 10) {
            var line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            if line.last == 13 { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}

public struct CodexAppServerClient: Sendable {
    private let locate: @Sendable () async -> URL?
    private let makeTransport: @Sendable () -> any JSONRPCTransport
    private let timeout: TimeInterval
    public init(locate: @escaping @Sendable () async -> URL? = { await ExecutableLocator.codexCLI() },
                makeTransport: @escaping @Sendable () -> any JSONRPCTransport = { StdioJSONRPCTransport() },
                timeout: TimeInterval = 15) {
        self.locate = locate; self.makeTransport = makeTransport; self.timeout = timeout
    }

    public func fetchQuota() async throws -> QuotaSnapshot {
        let transport = makeTransport()
        return try await withTaskCancellationHandler {
            defer { transport.close() }
            return try await withThrowingTaskGroup(of: QuotaSnapshot.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler { try await query(transport) }
                    onCancel: { transport.close() }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(max(0, timeout)))
                    throw QuotaError.transient("Codex 额度查询超时")
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw QuotaError.transient("Codex 额度查询中断") }
                return result
            }
        } onCancel: { transport.close() }
    }

    private func query(_ transport: any JSONRPCTransport) async throws -> QuotaSnapshot {
        try Task.checkCancellation()
        guard let executable = await locate() else { throw QuotaError.notConfigured("未找到 Codex") }
        try Task.checkCancellation()
        let stream = try await transport.start(executableURL: executable)
        try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"agent-island","title":"AgentIsland","version":"0.1.0"},"capabilities":null}}"#.utf8) + Data([10]))
        var framer = JSONRPCLineFramer()
        var initialized = false
        for try await chunk in stream {
            try Task.checkCancellation()
            for line in try framer.append(chunk) {
                guard let message = try? QuotaJSON.parse(line), let id = message["id"].integer else { continue }
                guard id == (initialized ? 2 : 1) else { continue }
                if message["error"].object != nil { throw QuotaError.transient("Codex 额度接口返回错误") }
                guard message["result"].object != nil else { throw QuotaError.decoding("Codex 额度响应缺少结果") }
                if !initialized {
                    initialized = true
                    try await transport.send(Data(#"{"jsonrpc":"2.0","method":"initialized"}"#.utf8) + Data([10]))
                    try await transport.send(Data(#"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":null}"#.utf8) + Data([10]))
                } else {
                    let result = message["result"]
                    guard result["rateLimits"].object != nil || result["rateLimitsByLimitId"].object != nil else {
                        throw QuotaError.decoding("Codex 额度响应缺少额度数据")
                    }
                    return CodexQuotaMapper.map(GetAccountRateLimitsResponse(value: result))
                }
            }
        }
        try Task.checkCancellation()
        throw QuotaError.transient("Codex 额度查询进程提前退出")
    }
}

extension GetAccountRateLimitsResponse {
    init(value: QuotaJSON) { self.value = value }
}
