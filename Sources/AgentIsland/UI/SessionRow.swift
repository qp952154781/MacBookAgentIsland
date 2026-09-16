import SwiftUI
import IslandCore

struct SessionRow: View {
    let session: AgentSession
    let now: Date
    var animated = true
    var expanded = false
    var toggle: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AgentGlyph(agent: session.agent, working: session.phase.isWorking, animated: animated).frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title).font(Theme.font(13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    ViewThatFits(in: .horizontal) {
                        ForEach(subtitles.dropLast(), id: \.self) { value in
                            Text(value).fixedSize(horizontal: true, vertical: false)
                        }
                        Text(subtitles.last ?? "").lineLimit(1).truncationMode(.tail)
                    }.font(Theme.font(10)).foregroundStyle(Theme.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(session.phase.label).font(Theme.font(9, weight: .medium)).foregroundStyle(Theme.phase(session.phase))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.phase(session.phase).opacity(0.13), in: Capsule())
                    Text(timing).font(Theme.font(9)).monospacedDigit().foregroundStyle(Theme.tertiary)
                }.lineLimit(1).fixedSize(horizontal: true, vertical: false).layoutPriority(1)
            }.frame(height: 42)
            GeometryReader { geometry in
                if let fraction = session.plan?.fraction ?? session.context?.fraction {
                    Capsule().fill(Theme.brand(session.agent).opacity(0.5))
                        .frame(width: max(0, geometry.size.width * min(1, fraction)), height: 2)
                }
            }.frame(height: 2)
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text("模型：\(session.model ?? "未知") · 本轮工具调用：\(session.toolCallsThisTurn)")
                    Text("上下文：\(session.context.map { String($0.usedTokens) } ?? "--") / \(session.context?.windowTokens.map(String.init) ?? "--")")
                    Text("最后输入：\(session.lastPrompt ?? "暂无记录")").lineLimit(1).truncationMode(.tail)
                }.font(Theme.font(10)).foregroundStyle(Theme.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 28).frame(height: 64)
            }
        }.contentShape(Rectangle()).onTapGesture(perform: toggle)
            .islandInteraction(.control("session:" + session.id))
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(session.title + (expanded ? "，收起详情" : "，展开详情"))
    }

    private var subtitles: [String] {
        let progress: String?
        if let plan = session.plan { progress = "计划 \(plan.completed)/\(plan.total)" }
        else { progress = session.context.map { "上下文 \($0.usedTokens / 1000)K" } }
        let components = [session.projectName, session.activity, progress]
        let candidates = [components, [session.projectName, progress], [session.projectName]]
            .map { $0.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
        return candidates.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
    private var timing: String {
        guard let start = session.turnStartedAt else { return "" }
        return Theme.duration((session.turnEndedAt ?? now).timeIntervalSince(start))
    }
}
