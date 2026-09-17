import Foundation
import Testing
import IslandCore

@Test(arguments: [
    ("claude", #""claude""#),
    ("codex", #""codex""#),
    ("custom.team-credits", #""custom.team-credits""#)
])
func providerIDsEncodeAndDecodeAsBareStrings(rawValue: String, json: String) throws {
    let id = ProviderID(rawValue: rawValue)
    #expect(try JSONEncoder().encode(id) == Data(json.utf8))
    #expect(try JSONDecoder().decode(ProviderID.self, from: Data(json.utf8)) == id)
    #expect(Set([id, ProviderID(rawValue: rawValue)]).count == 1)
}

@Test func providerIdentityRejectsNonStringJSON() {
    for json in [#"{"rawValue":"claude"}"#, "null", "12", "[]"] {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProviderID.self, from: Data(json.utf8))
        }
    }
}

@Test(arguments: [ProviderID.claude, .codex, ProviderID(rawValue: "custom.team-credits")])
func providerModelWireFormatPreservesAgentFields(agent: ProviderID) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let decoder = JSONDecoder()
    let now = Date(timeIntervalSinceReferenceDate: 0)
    let raw = agent.rawValue
    let quota = QuotaSnapshot(agent: agent, windows: [], source: .mock, fetchedAt: now)
    let quotaJSON = #"{"agent":"\#(raw)","fetchedAt":0,"source":"mock","windows":[]}"#
    #expect(try encoder.encode(quota) == Data(quotaJSON.utf8))
    #expect(try decoder.decode(QuotaSnapshot.self, from: Data(quotaJSON.utf8)) == quota)
    let session = AgentSession(agent: agent, sessionId: "fixture", title: "Fixture", lastActivityAt: now)
    let sessionJSON = #"{"agent":"\#(raw)","id":"\#(raw):fixture","lastActivityAt":0,"phase":"idle","sessionId":"fixture","title":"Fixture","toolCallsThisTurn":0}"#
    #expect(try encoder.encode(session) == Data(sessionJSON.utf8))
    #expect(try decoder.decode(AgentSession.self, from: Data(sessionJSON.utf8)) == session)
    let update = QuotaUpdate(agent: agent, snapshot: quota, health: .ok)
    let updateJSON = #"{"agent":"\#(raw)","health":{"ok":{}},"snapshot":\#(quotaJSON)}"#
    #expect(try encoder.encode(update) == Data(updateJSON.utf8))
    #expect(try decoder.decode(QuotaUpdate.self, from: Data(updateJSON.utf8)) == update)
}

@Test func providerDictionaryKeysRetainTheOriginalEnumWireFormat() throws {
    // Non-String dictionary keys encoded as alternating keys/values before this refactor.
    let expected = Data(#"["claude",7]"#.utf8)
    #expect(try JSONEncoder().encode([ProviderID.claude: 7]) == expected)
    #expect(try JSONDecoder().decode([ProviderID: Int].self, from: expected) == [.claude: 7])
}

@Test func providerRegistryPreservesBuiltInOrderMetadataAndCapabilities() {
    #expect(ProviderID.claude.rawValue == "claude")
    #expect(ProviderID.codex.rawValue == "codex")
    #expect(ProviderRegistry.orderedIDs == [.claude, .codex])
    #expect(ProviderRegistry.ordered.map(\.id) == [.claude, .codex])
    #expect(ProviderRegistry.ordered.map(\.displayName) == ["Claude", "Codex"])
    #expect(ProviderRegistry.ordered.allSatisfy { $0.hasQuota && $0.hasSessions })
    let claude = ProviderRegistry.descriptor(for: .claude)
    let codex = ProviderRegistry.descriptor(for: .codex)
    #expect(claude.brandColor == .init(red: 0.851, green: 0.467, blue: 0.341))
    #expect(claude.glyphColor == claude.brandColor)
    #expect(codex.brandColor == .init(red: 0.541, green: 0.706, blue: 1))
    let codexGlyph = ProviderDescriptor.RGB(red: 232.0 / 255, green: 234.0 / 255, blue: 240.0 / 255)
    #expect(codex.glyphColor == codexGlyph)
    #expect(claude.iconSource == .installedApplication(bundleName: "Claude.app",
        resourceNames: ["TrayIconTemplate@2x.png", "TrayIconTemplate-Dark@2x.png"], fallback: .claude))
    #expect(codex.iconSource == .installedApplication(bundleName: "ChatGPT.app",
        resourceNames: ["chatgptTemplate@2x.png", "icon-codex-dark-color.png"], fallback: .codex))
}

@Test func unknownProviderUsesNeutralMetadataWithoutRegistration() {
    let id = ProviderID(rawValue: "custom.team-credits")
    let descriptor = ProviderRegistry.descriptor(for: id)
    #expect(descriptor.id == id)
    #expect(descriptor.displayName == "custom.team-credits")
    #expect(descriptor.brandColor == .init(red: 0.7, green: 0.7, blue: 0.7))
    #expect(descriptor.glyphColor == descriptor.brandColor)
    #expect(descriptor.iconSource == .none)
    #expect(descriptor.iconSource.fallback == .generic)
    #expect(!descriptor.hasQuota && !descriptor.hasSessions)
    #expect(!ProviderRegistry.orderedIDs.contains(id))
    #expect(ProviderDescriptor.IconSource.builtIn(.claude).fallback == .claude)
    #expect(ProviderDescriptor.IconSource.builtIn(.codex).fallback == .codex)
}

@Test func providerWingPositionsFollowTheListAndHandleMissingEntries() {
    let empty = ProviderLayout.wings(in: [])
    #expect(empty.left == nil && empty.right == nil)
    let single = ProviderLayout.wings(in: [.codex])
    #expect(single.left == .codex && single.right == nil)
    let reversed = ProviderLayout.wings(in: [.codex, .claude])
    #expect(reversed.left == .codex && reversed.right == .claude)
    let current = ProviderLayout.wings()
    #expect(current.left == .claude && current.right == .codex)
    let unknown = ProviderID(rawValue: "custom.team-credits")
    #expect(ProviderLayout.provider(at: 2, in: [.claude, .codex, unknown]) == unknown)
    for index in [-1, 1, 2, Int.max] {
        #expect(ProviderLayout.provider(at: index, in: [.codex]) == nil)
    }
}

@Test func providerSessionColumnsHandleZeroOneAndMoreProvidersWithoutChangingSort() {
    let custom = ProviderID(rawValue: "custom.team-credits")
    let input = [ProviderID.claude, .codex, custom].flatMap { agent in
        [AgentSession(agent: agent, sessionId: "older", title: "Older", phase: .thinking,
                      lastActivityAt: Date(timeIntervalSinceReferenceDate: 0)),
         AgentSession(agent: agent, sessionId: "newer", title: "Newer", phase: .thinking,
                      lastActivityAt: Date(timeIntervalSinceReferenceDate: 1))]
    }
    #expect(SessionDisplayOrder.columns(input, providers: []).isEmpty)
    for providers: [ProviderID] in [[.codex], [.codex, .claude], [.claude, .codex, custom]] {
        let columns = SessionDisplayOrder.columns(input, providers: providers)
        #expect(columns.count == providers.count)
        for (id, sessions) in zip(providers, columns) {
            #expect(sessions.allSatisfy { $0.agent == id })
            #expect(sessions.map(\.sessionId) == ["newer", "older"])
        }
    }
}
