import Foundation
import SwiftUI
import Testing
import IslandCore
@testable import AgentIsland

@MainActor @Test func providerRenderingSelectsBuiltInStylesAndDefaultsForUnknownIDs() {
    #expect(LayerAnimationView.Kind.provider(.claude) == .claude)
    #expect(LayerAnimationView.Kind.provider(.codex) == .codex)
    let unknown = ProviderID(rawValue: "custom.team-credits")
    #expect(LayerAnimationView.Kind.provider(unknown) == .generic)
    #expect(Theme.brand(.claude) == Color(red: 0.851, green: 0.467, blue: 0.341))
    #expect(Theme.brand(.codex) == Color(red: 0.541, green: 0.706, blue: 1))
    #expect(Theme.glyph(.claude) == Theme.brand(.claude))
    #expect(Theme.glyph(.codex) == Color(red: 232.0 / 255, green: 234.0 / 255, blue: 240.0 / 255))
    #expect(Theme.brand(unknown) == Color(red: 0.7, green: 0.7, blue: 0.7))
    #expect(Theme.glyph(unknown) == Theme.brand(unknown))
    let actions = ConnectionActions()
    #expect(actions.loginCommand(for: .claude) == "claude auth login")
    #expect(actions.loginCommand(for: .codex) == "codex login")
    #expect(actions.loginCommand(for: unknown) == nil)
}

@MainActor @Test func providerColumnLabelsAreSafeForShortOrReorderedLists() {
    #expect(ExpandedView.emptySessionLabel(column: 0) == "暂无 Claude 会话")
    #expect(ExpandedView.emptySessionLabel(column: 1) == "暂无 Codex 会话")
    #expect(ExpandedView.emptySessionLabel(column: 0, providers: [.codex]) == "暂无 Codex 会话")
    #expect(ExpandedView.emptySessionLabel(column: 1, providers: [.codex]) == "暂无活跃会话")
    #expect(ExpandedView.emptySessionLabel(column: 0, providers: []) == "暂无活跃会话")
    #expect(ExpandedView.emptySessionLabel(column: -1, providers: []) == "暂无活跃会话")
    #expect(ExpandedView.emptySessionLabel(column: 1, providers: [.codex, .claude]) == "暂无 Claude 会话")
}
