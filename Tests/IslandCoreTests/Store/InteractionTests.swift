import Foundation
import Testing
@testable import IslandCore

@Test func hoverExpansionPinningAndOutsideDismissal() {
    var state = IslandInteraction()
    state.setHovered(true)
    #expect(!state.expanded)
    state.settleHover()
    #expect(state.expanded && !state.pinned)
    state.click()
    state.setHovered(false)
    state.settleHover()
    #expect(state.expanded && state.pinned)
    state.setHovered(true)
    state.click()
    state.settleHover()
    #expect(!state.expanded)
    state.setHovered(false)
    state.settleHover()
    state.setHovered(true)
    state.settleHover()
    #expect(state.expanded)
    state.clickOutside()
    state.settleHover()
    #expect(!state.expanded)
}

@Test func clickModeIgnoresHoverAndTogglesOnlyOnClick() {
    var state = IslandInteraction()
    state.setMethod(.click)
    for _ in 0..<3 {
        state.setHovered(true); state.settleHover()
        #expect(!state.expanded)
        state.setHovered(false); state.settleHover()
        #expect(!state.expanded)
    }
    state.click()
    state.setHovered(true); state.settleHover()
    state.setHovered(false); state.settleHover()
    #expect(state.expanded && state.pinned)
    state.click()
    #expect(!state.expanded)
    state.click(); state.clickOutside()
    #expect(!state.expanded && !state.pinned)
}

@Test func changingExpansionMethodCannotOpenIslandOrLeaveHoverOpen() {
    var state = IslandInteraction()
    state.setHovered(true)
    state.setMethod(.click)
    state.settleHover()
    #expect(!state.expanded)
    state.setMethod(.hover)
    state.settleHover()
    #expect(!state.expanded)
    state.setHovered(false); state.settleHover()
    state.setHovered(true); state.settleHover()
    #expect(state.expanded)
    state.setMethod(.click)
    #expect(!state.expanded)
    state.click(); state.setMethod(.hover)
    #expect(state.pinned && state.expanded)
}

@MainActor @Test func expansionSettingNotifiesImmediatelyAndActivityFollowsWorkingSessions() {
    let settings = AppSettings()
    var state = IslandInteraction()
    settings.onChange = { state.setMethod(settings.expansionMethod) }
    #expect(settings.expansionMethod == .hover)
    settings.expansionMethod = .click
    #expect(state.method == .click)
    settings.onChange = nil

    let store = IslandStore.mock(.busy)
    #expect(store.workingSessions(for: .claude).count == 1)
    #expect(store.workingSessions(for: .codex).first?.plan?.fraction == 3.0 / 7)
    store.sessions.removeAll { $0.agent == .claude }
    #expect(store.workingSessions(for: .claude).isEmpty && store.anyWorking)
    store.sessions[0].phase = .waitingInput
    #expect(!store.anyWorking && store.workingSessions(for: .codex).isEmpty)
    for phase in [SessionPhase.waitingPermission, .error, .ended, .idle] {
        store.sessions[0].phase = phase
        #expect(!store.anyWorking)
    }
}
