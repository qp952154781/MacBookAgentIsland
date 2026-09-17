import AppKit
import SwiftUI
import UniformTypeIdentifiers
import IslandCore

struct CustomSourceSettings: View {
    @Bindable var settings: AppSettings
    let store: IslandStore
    var snapshot = false
    var previewOnly = false
    var snapshotForm = false
    var snapshotDeletion: ProviderID? = nil
    @State private var draft: CustomSource?
    @State private var pendingDeletion: ProviderID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("自定义数据源").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                SourceButton("添加") { pendingDeletion = nil; draft = CustomSource(colorIndex: settings.customSources.count) }
            }
            if settings.customSources.isEmpty { Text("用一条命令显示任意工具的额度").font(.caption).foregroundStyle(.secondary) }
            ForEach(settings.declarations.filter { descriptor in settings.customSources.contains { $0.id == descriptor.id } }) { descriptor in
                if let source = settings.customSources.first(where: { $0.id == descriptor.id }) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(source.name).lineLimit(1)
                            Text("每 \(source.intervalMinutes) 分钟").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if pendingDeletion == source.id || (snapshot && snapshotDeletion == source.id) {
                                SourceButton("确认删除") {
                                    settings.deleteCustomSource(source.id)
                                    if draft?.id == source.id { draft = nil }
                                    pendingDeletion = nil
                                }.foregroundStyle(.red)
                                SourceButton("取消") { pendingDeletion = nil }
                            } else {
                                SourceButton("编辑") { pendingDeletion = nil; draft = source }
                                SourceButton("删除") { pendingDeletion = source.id }
                            }
                        }
                        if let warning = store.quotaWarnings[source.id], !warning.isEmpty {
                            Text(warning.joined(separator: "；")).font(.caption).foregroundStyle(.orange)
                        }
                        if let diagnostic = store.quotaDiagnostics[source.id] { Text(diagnostic).font(.caption).foregroundStyle(.orange).lineLimit(3) }
                    }
                }
            }
            if let draft {
                CustomSourceEditor(initial: draft, snapshot: snapshot, previewOnly: previewOnly || snapshot) { source in
                    settings.saveCustomSource(source); self.draft = nil
                } cancel: { self.draft = nil }
                .id(draft.id)
            } else if snapshotForm {
                CustomSourceEditor(initial: CustomSource(name: "示例额度", command: "echo 62"), snapshot: true,
                                   previewOnly: true, initialPreview: CustomSourceEditor.samplePreview, save: { _ in }, cancel: {})
            }
        }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .onDisappear { pendingDeletion = nil }
    }
}

struct SourceButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
}

struct CustomSourceEditor: View {
    @State private var source: CustomSource
    @State private var preview: CustomQuotaResult?
    @State private var error: String?
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    let snapshot: Bool
    let previewOnly: Bool
    let save: (CustomSource) -> Void
    let cancel: () -> Void
    init(initial: CustomSource, snapshot: Bool = false, previewOnly: Bool = false,
         initialPreview: CustomQuotaResult? = nil, save: @escaping (CustomSource) -> Void, cancel: @escaping () -> Void) {
        _source = State(initialValue: initial); _preview = State(initialValue: initialPreview)
        self.snapshot = snapshot; self.previewOnly = previewOnly; self.save = save; self.cancel = cancel
    }
    static var samplePreview: CustomQuotaResult {
        .init(snapshot: .init(agent: .init(rawValue: "custom-preview"), windows: [
            .init(id: "preview", kind: .other, label: "示例额度", usedPercent: 38)
        ], source: .customCommand, fetchedAt: SnapshotExporter.now), warnings: [])
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("名称（必填）").font(.caption)
            input($source.name, height: 28, multiline: false)
            Text("命令（必填）").font(.caption)
            input($source.command, height: 90, multiline: true)
            Text("命令以明文保存在本机设置中。请不要把 API Key 直接写在命令里，建议在脚本中从钥匙串读取。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("若提示找不到命令，请使用绝对路径").font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                Text("刷新间隔").font(.caption)
                Spacer()
                ForEach(CustomSource.intervals, id: \.self) { minutes in
                    SourceButton("\(minutes) 分钟") { source.intervalMinutes = minutes }
                        .foregroundStyle(source.intervalMinutes == minutes ? Color.accentColor : Color.primary)
                        .accessibilityAddTraits(source.intervalMinutes == minutes ? .isSelected : [])
                }
            }
            HStack {
                SourceButton("从应用选取…", action: pickApplication)
                if source.applicationPath != nil {
                    Text("已选择应用图标").font(.caption).foregroundStyle(.secondary)
                    SourceButton("移除") { source.applicationPath = nil }
                }
            }
            HStack {
                Text("颜色").font(.caption)
                ForEach(CustomSource.palette.indices, id: \.self) { index in
                    Button { source.colorIndex = index } label: {
                        Circle().fill(Theme.color(CustomSource.palette[index])).frame(width: 18, height: 18)
                            .overlay { if source.colorIndex == index { Circle().stroke(Color.primary, lineWidth: 2).padding(-3) } }
                            .padding(4)
                    }.buttonStyle(.plain).accessibilityLabel("颜色 \(index + 1)")
                }
            }
            HStack {
                SourceButton(busy ? "运行中…" : "测试运行", action: testRun).disabled(busy || !source.isValid)
                Spacer()
                SourceButton("取消") { task?.cancel(); cancel() }
                SourceButton("保存") { task?.cancel(); save(source) }.disabled(!source.isValid)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if let preview {
                VStack(alignment: .leading, spacing: 6) {
                    Text("测试成功 · 结果预览").font(.caption).foregroundStyle(.secondary)
                    ForEach(preview.snapshot.windows) { window in
                        HStack {
                            Text(window.label).lineLimit(1)
                            Spacer()
                            Text(QuotaDisplayMode.remaining.percent(window)).monospacedDigit()
                            if window.resetsAt != nil { Text(DisplayTime.reset(window.resetsAt, now: snapshot ? SnapshotExporter.now : Date())).foregroundStyle(.secondary) }
                        }.font(.caption)
                    }
                    if let plan = preview.snapshot.plan { Text("套餐：" + plan).font(.caption) }
                    if let note = preview.snapshot.note { Text(note).font(.caption).lineLimit(2) }
                    ForEach(preview.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }.onDisappear { task?.cancel() }
            .onChange(of: source) { _, _ in task?.cancel(); task = nil; busy = false; preview = nil; error = nil }
    }
    @ViewBuilder private func input(_ text: Binding<String>, height: CGFloat, multiline: Bool) -> some View {
        if snapshot {
            // ImageRenderer does not render native editors. Match the live editor's frame and typography.
            Text(text.wrappedValue).font(multiline ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(6)
                .frame(height: height).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
        } else {
            SourceTextInput(text: text, multiline: multiline).frame(height: height)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
        }
    }
    private func testRun() {
        task?.cancel(); error = nil; preview = nil
        guard !snapshot, !previewOnly else { preview = Self.samplePreview; return }
        let captured = source
        busy = true
        task = Task {
            do {
                let parsed = try await CustomCommandRunner.shared.run(captured)
                guard !Task.isCancelled else { return }
                preview = parsed
            } catch {
                guard !Task.isCancelled else { return }
                self.error = (error as? CustomSourceError)?.message ?? "运行已暂停，请解锁或唤醒后重试"
            }
            busy = false
        }
    }
    private func pickApplication() {
        guard !snapshot else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.prompt = "选取应用"
        if panel.runModal() == .OK, let url = panel.url { source.applicationPath = url.path }
    }
}

private struct SourceTextInput: NSViewRepresentable {
    @Binding var text: String
    let multiline: Bool
    func makeCoordinator() -> Coordinator { Coordinator(text: $text, multiline: multiline) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = multiline
        let view = NSTextView()
        view.isRichText = false; view.importsGraphics = false; view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false; view.isAutomaticTextReplacementEnabled = false
        // Native undo buffers stay in memory and disappear with the editor.
        view.allowsUndo = true; view.drawsBackground = false; view.textColor = .labelColor
        view.font = multiline ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        view.textContainerInset = NSSize(width: 4, height: 5)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator; view.string = text; scroll.documentView = view
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.text = $text
        if let editor = view.documentView as? NSTextView, editor.string != text { editor.string = text }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let multiline: Bool
        init(text: Binding<String>, multiline: Bool) { self.text = text; self.multiline = multiline }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = multiline ? editor.string : editor.string.components(separatedBy: .newlines).joined(separator: " ")
        }
    }
}
