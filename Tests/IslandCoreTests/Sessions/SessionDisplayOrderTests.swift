import Foundation
import Testing
@testable import IslandCore

private func displaySession(_ id: String, phase: SessionPhase = .thinking,
                            project: String? = "示例", time: TimeInterval = 0) -> AgentSession {
    AgentSession(agent: .codex, sessionId: id, title: id, projectName: project,
                 phase: phase, lastActivityAt: Date(timeIntervalSince1970: time))
}

@Test func displaySortHonorsAllStatusTiers() {
    let input: [AgentSession] = [
        displaySession("ended", phase: .ended, time: 900),
        displaySession("waiting", phase: .waitingInput, time: 800),
        displaySession("permission", phase: .waitingPermission, time: 700),
        displaySession("idle", phase: .idle, time: 600),
        displaySession("error", phase: .error, time: 500),
        displaySession("think", phase: .thinking, time: 400),
        displaySession("compact", phase: .compacting, time: 300),
        displaySession("retry", phase: .retrying, time: 200),
        displaySession("tool", phase: .runningTool, time: 100)
    ]
    #expect(SessionDisplayOrder.sorted(input).map(\.sessionId)
            == ["tool", "think", "compact", "retry", "permission", "waiting", "error", "idle", "ended"])
}

@Test func displaySortKeepsProjectsAdjacentByTheirNewestSession() {
    let input = [displaySession("a-old", project: "A", time: 1),
                 displaySession("b-new", project: "B", time: 50),
                 displaySession("none", project: nil, time: 1000),
                 displaySession("a-new", project: "A", time: 100),
                 displaySession("b-old", project: "B", time: 2),
                 displaySession("permission", phase: .waitingPermission, project: "A", time: 2000)]
    #expect(SessionDisplayOrder.sorted(input).map(\.sessionId) == ["a-new", "a-old", "b-new", "b-old", "none", "permission"])
    // A missing project is last within its status tier, never behind a lower tier.
    #expect(SessionDisplayOrder.sorted([displaySession("nil-tool", phase: .runningTool, project: nil), input[3]])
        .first?.sessionId == "nil-tool")
}

@Test func displaySortIsDeterministicAcrossTiesAndInputPermutations() {
    let input = [displaySession("z", project: "B"), displaySession("b", project: "A"),
                 displaySession("a", project: "A"), displaySession("d", project: nil), displaySession("c", project: nil)]
    let ordered = SessionDisplayOrder.sorted(input)
    #expect(ordered.map(\.sessionId) == ["a", "b", "z", "c", "d"])
    #expect(ordered == SessionDisplayOrder.sorted(input))
    #expect(ordered == SessionDisplayOrder.sorted(input.reversed()))
    #expect(SessionDisplayOrder.sorted([]).isEmpty)
}

@Test(arguments: [(2, 10), (10, 2), (0, 5), (5, 0), (0, 0), (1, 1)])
func displayColumnsKeepProvidersSeparate(counts: (Int, Int)) {
    let input = [AgentKind.claude, .codex].flatMap { agent in
        (0..<(agent == .claude ? counts.0 : counts.1)).map { index in
            AgentSession(agent: agent, sessionId: "\(index)", title: "样例", projectName: index.isMultiple(of: 2) ? "A" : nil,
                         phase: index.isMultiple(of: 3) ? .runningTool : .waitingInput,
                         lastActivityAt: Date(timeIntervalSince1970: Double(index)))
        }
    }
    let columns = SessionDisplayOrder.columns(input.reversed())
    #expect(columns.count == 2)
    #expect(columns[0].count == counts.0 && columns[1].count == counts.1)
    for (index, agent) in [AgentKind.claude, .codex].enumerated() {
        #expect(columns[index].allSatisfy { $0.agent == agent })
        #expect(columns[index] == SessionDisplayOrder.sorted(input.filter { $0.agent == agent }))
    }
}

@Test func columnProjectRecencyIsIndependentOfTheOtherProvider() {
    var claude = displaySession("claude-a", project: "A", time: 1000)
    claude.agent = .claude
    let input = [claude, displaySession("codex-a", project: "A", time: 1),
                 displaySession("codex-b", project: "B", time: 100),
                 displaySession("codex-none", project: nil, time: 2000)]
    #expect(SessionDisplayOrder.columns(input)[1].map(\.sessionId) == ["codex-b", "codex-a", "codex-none"])
    #expect(SessionDisplayOrder.sorted(input).map(\.sessionId) == ["claude-a", "codex-a", "codex-b", "codex-none"])
}
