import Foundation
import Testing
@testable import IslandCore

private let fixtureNow = Date(timeIntervalSince1970: 1_800_000_000)
private let fakeAccess = "sk-ant-oat01-FAKE-ACCESS"
private let fakeRefresh = "sk-ant-FAKE-REFRESH"

@Test func credentialCacheInvalidationAndMissingItemFallback() async throws {
    let data = try quotaFixture("credentials.json")
    let executor = FakeQuotaExecutor([.success(.init(stdout: data, exitCode: 0)), .success(.init(stdout: data, exitCode: 0))])
    let store = ClaudeCredentialStore(executor: executor, now: { fixtureNow }, readFallback: { Issue.record("Unexpected fallback"); return nil })
    let credential = try await store.credentials()
    #expect(credential.subscriptionType == "max")
    #expect(credential.rateLimitTier == "default_claude_max_5x")
    #expect(credential.scopes == ["user:profile", "user:inference"])
    #expect(credential.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
    _ = try await store.credentials()
    #expect(await executor.calls.count == 1)
    await store.invalidate()
    _ = try await store.credentials()
    #expect(await executor.calls.count == 2)
    let call = try #require(await executor.calls.first)
    #expect(call.executable.path == "/usr/bin/security")
    #expect(call.arguments == ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
    #expect(call.timeout == 5)
    for output in [QuotaCommandOutput(stdout: Data(), exitCode: 44), QuotaCommandOutput(stdout: Data(), exitCode: 1, itemNotFound: true)] {
        let fallback = ClaudeCredentialStore(executor: FakeQuotaExecutor([.success(output)]), now: { fixtureNow }, readFallback: { data })
        #expect(try await fallback.credentials().subscriptionType == "max")
        let absent = ClaudeCredentialStore(executor: FakeQuotaExecutor([.success(output)]), readFallback: { nil })
        await #expect(throws: QuotaError.notConfigured(ClaudeCredentialStore.loginMessage)) { try await absent.credentials() }
    }
}

@Test func credentialExpiredMalformedDeniedAndProcessErrors() async throws {
    let expired = ClaudeCredentialStore(executor: FakeQuotaExecutor([.success(.init(stdout: try quotaFixture("credentials-expired.json"), exitCode: 0))]), now: { fixtureNow }, readFallback: { nil })
    #expect(try await expired.credentials().expiresAt == Date(timeIntervalSince1970: 1))
    for data in [Data("broken".utf8), Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8), Data(#"{"claudeAiOauth":{"refreshToken":"sk-ant-FAKE-REFRESH"}}"#.utf8)] {
        let store = ClaudeCredentialStore(executor: FakeQuotaExecutor([.success(.init(stdout: data, exitCode: 0))]), readFallback: { nil })
        await #expect(throws: QuotaError.decoding("Claude 凭据格式无效")) { try await store.credentials() }
    }
    for result: Result<QuotaCommandOutput, QuotaError> in [.failure(.transient(fakeAccess)), .success(.init(stdout: Data(fakeAccess.utf8), exitCode: 36))] {
        let store = ClaudeCredentialStore(executor: FakeQuotaExecutor([result]), readFallback: { Issue.record("Must not fall back on denial"); return nil })
        await #expect(throws: QuotaError.transient("无法读取 Claude 登录信息")) { try await store.credentials() }
    }
    let fileFailure = ClaudeCredentialStore(executor: FakeQuotaExecutor([.success(.init(stdout: Data(), exitCode: 44))]), readFallback: { throw CocoaError(.fileReadNoPermission) })
    await #expect(throws: QuotaError.transient("无法读取 Claude 登录文件")) { try await fileFailure.credentials() }
}

@Test func credentialExpiryEndsCacheReuse() async throws {
    let data = try quotaFixture("credentials.json"), clock = FakeQuotaClock()
    let executor = FakeQuotaExecutor([.success(.init(stdout: data, exitCode: 0)), .success(.init(stdout: data, exitCode: 0))])
    let store = ClaudeCredentialStore(executor: executor, now: { clock.now() }, readFallback: { nil })
    _ = try await store.credentials()
    clock.advance(200_000_000)
    #expect(try await store.credentials().expiresAt == clock.now())
    #expect(await executor.calls.count == 2)
}

@Test func usageSuccessHeadersAndPlan() async throws {
    let executor = FakeQuotaExecutor([.success(.init(stdout: try quotaFixture("credentials.json"), exitCode: 0))])
    let http = FakeUsageHTTP([.success(.init(statusCode: 200, data: try quotaFixture("claude-limits.json")))])
    let store = ClaudeCredentialStore(executor: executor, now: { fixtureNow }, readFallback: { nil })
    let client = ClaudeOAuthUsageClient(credentials: store, http: http, executor: executor, locate: { nil }, now: { fixtureNow }, refresher: FakeClaudeRefresher())
    let result = try await ClaudeQuotaProvider(client: client).fetchQuota()
    #expect(result.plan == "Max 5x")
    #expect(result.source == .claudeOAuth)
    #expect(result.fetchedAt == fixtureNow)
    let request = try #require(await http.requests.first)
    #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
    #expect(request.httpMethod == "GET")
    #expect(request.timeoutInterval == 15)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fakeAccess)")
    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "AgentIsland/0.1.0")
}

@Test func usageStatusCodesAndCacheInvalidation() async throws {
    let data = try quotaFixture("credentials.json")
    for status in [401, 403, 429, 500, 503, 400, 302] {
        let executor = FakeQuotaExecutor([.success(.init(stdout: data, exitCode: 0)), .success(.init(stdout: data, exitCode: 0))])
        let store = ClaudeCredentialStore(executor: executor, now: { fixtureNow }, readFallback: { nil })
        let http = FakeUsageHTTP([.success(.init(statusCode: status, data: Data(fakeAccess.utf8), retryAfter: "42"))])
        let client = ClaudeOAuthUsageClient(credentials: store, http: http, executor: executor, locate: { nil }, now: { fixtureNow }, refresher: FakeClaudeRefresher())
        do { _ = try await client.fetchQuota(); Issue.record("Expected status failure") }
        catch let error as QuotaError {
            #expect(!error.message.contains(fakeAccess))
            if status == 401 || status == 403 { #expect(error == .transient(ClaudeOAuthUsageClient.recoveringMessage)) }
            else if status == 429 { #expect(error.message.contains("42 秒")) }
            else if case .transient = error {} else { Issue.record("Expected transient") }
        }
        _ = try await store.credentials()
        #expect(await executor.calls.count == (status == 401 || status == 403 ? 2 : 1))
    }
}

@Test func usageNetworkAndDecodingErrorsAreSanitized() async throws {
    let data = try quotaFixture("credentials.json")
    for response: Result<UsageHTTPResponse, QuotaError> in [.failure(.transient(fakeAccess)), .success(.init(statusCode: 200, data: Data(fakeAccess.utf8)))] {
        let store = ClaudeCredentialStore(executor: FakeQuotaExecutor([.success(.init(stdout: data, exitCode: 0))]), now: { fixtureNow }, readFallback: { nil })
        let client = ClaudeOAuthUsageClient(credentials: store, http: FakeUsageHTTP([response]), locate: { nil })
        do { _ = try await client.fetchQuota(); Issue.record("Expected failure") }
        catch { #expect(!String(describing: error).contains(fakeAccess)) }
    }
}

@Test func credentialAndSnapshotLeakRegression() async throws {
    let credential = try JSONDecoder().decode(ClaudeCredential.self, from: quotaFixture("credentials.json"))
    #expect(!Mirror(reflecting: credential).children.contains { $0.label == "refreshToken" || $0.label == "accessToken" })
    var texts = [String(describing: credential), String(reflecting: credential)]
    var credentialDump = ""
    dump(credential, to: &credentialDump)
    texts.append(credentialDump)
    let store = ClaudeCredentialStore(executor: FakeQuotaExecutor([.success(.init(stdout: try quotaFixture("credentials.json"), exitCode: 0))]), readFallback: { nil })
    let body = Data("{\"limits\":[{\"kind\":\"weekly_scoped\",\"percent\":1,\"scope\":{\"model\":{\"display_name\":\"\(fakeAccess)\"}}}]}".utf8)
    let client = ClaudeOAuthUsageClient(credentials: store, http: FakeUsageHTTP([.success(.init(statusCode: 200, data: body))]), locate: { nil })
    let snapshot = try await client.fetchQuota()
    texts.append(String(describing: snapshot))
    var snapshotDump = ""
    dump(snapshot, to: &snapshotDump)
    texts.append(snapshotDump)
    texts.append(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self))
    let error = QuotaError.unauthorized(ClaudeCredentialStore.expiredMessage)
    texts.append(String(describing: error))
    var errorDump = ""
    dump(error, to: &errorDump)
    texts.append(errorDump)
    let health = ProviderHealth.needsSetup(message: error.message)
    texts.append(String(decoding: try JSONEncoder().encode(health), as: UTF8.self))
    for text in texts { #expect(!text.contains(fakeAccess)); #expect(!text.contains(fakeRefresh)) }
}
