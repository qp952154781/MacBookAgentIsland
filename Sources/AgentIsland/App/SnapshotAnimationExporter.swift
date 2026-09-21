import AppKit
import SwiftUI
import IslandCore

@MainActor enum SnapshotAnimationExporter {
    static let gifWidth = 900
    nonisolated static let maximumGIFBytes = 3_000_000

    static func export(to directory: String) async throws {
        let glyphs = BrandGlyphLoader()
        await glyphs.refresh()

        let store = IslandStore.mock(.idle, now: SnapshotExporter.now)
        SnapshotExporter.configureReadme(store, scenario: "readme-expanded")
        let notch = SnapshotExporter.metrics(hasNotch: true)
        let config = ExpandedView.layoutConfig(store: store, notch: notch)
        let contentHeight = ExpandedView.contentHeight(store: store, notch: notch)
        let collapsedSize = IslandLayout.size(for: .collapsed, notch: notch, config: config,
                                              expandedContentHeight: contentHeight)
        let expandedSize = IslandLayout.size(for: .expanded, notch: notch, config: config,
                                             expandedContentHeight: contentHeight)
        let timeline = SnapshotAnimationTimeline()
        let plan = SnapshotAnimationFramePlan.make(
            timeline: timeline, collapsedSize: collapsedSize, expandedSize: expandedSize
        )

        var pngFrames: [(name: String, data: Data)] = []
        var gifFrames: [GIFFrame] = []
        pngFrames.reserveCapacity(plan.count)
        gifFrames.reserveCapacity(plan.count)
        for frame in plan {
            let scene = SnapshotAnimationScene(store: store, notch: notch, frame: frame,
                                               expandedSize: expandedSize, now: SnapshotExporter.now)
                .environment(\.brandGlyphLoader, glyphs)
            let renderer = ImageRenderer(content: scene)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw SnapshotExporter.ExportError.renderFailed("animation-frame-\(frame.index)")
            }
            let resized = try resize(image, width: gifWidth)
            pngFrames.append((String(format: "frame-%03d.png", frame.index), png))
            gifFrames.append(GIFFrame(image: resized, delay: frame.delay))
        }

        let report = try await Task.detached(priority: .utility) {
            try write(pngFrames: pngFrames, gifFrames: gifFrames, timeline: timeline, to: directory)
        }.value
        let mebibytes = Double(report.byteCount) / 1_048_576
        print(String(format: "已生成 %d 张动画帧和 demo-expand.gif：%dx%d px，%.2f MiB，GIF %.2f fps，目录 %@",
                     plan.count, report.width, report.height, mebibytes, report.frameRate, directory))
    }

    private static func resize(_ image: CGImage, width: Int) throws -> CGImage {
        let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AnimationExportError.resizeFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw AnimationExportError.resizeFailed }
        return result
    }

    nonisolated private static func write(pngFrames: [(name: String, data: Data)],
                                          gifFrames: [GIFFrame], timeline: SnapshotAnimationTimeline,
                                          to directory: String) throws -> AnimationExportReport {
        let manager = FileManager.default
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        let framesDirectory = output.appendingPathComponent("frames", isDirectory: true)
        try manager.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        for frame in pngFrames {
            try frame.data.write(to: framesDirectory.appendingPathComponent(frame.name), options: .atomic)
        }

        let finalURL = output.appendingPathComponent("demo-expand.gif")
        let candidateURL = output.appendingPathComponent(".demo-expand-candidate.gif")
        defer { try? manager.removeItem(at: candidateURL) }
        var lastSize = 0
        for step in [1, 2, 3, 4, 5, 6, 8, 10] {
            let candidateFrames = downsample(gifFrames, step: step)
            if manager.fileExists(atPath: candidateURL.path) { try manager.removeItem(at: candidateURL) }
            try GIFEncoder.write(candidateFrames, to: candidateURL)
            let attributes = try manager.attributesOfItem(atPath: candidateURL.path)
            lastSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard lastSize <= maximumGIFBytes else { continue }
            if manager.fileExists(atPath: finalURL.path) { try manager.removeItem(at: finalURL) }
            try manager.moveItem(at: candidateURL, to: finalURL)
            guard let first = candidateFrames.first else { throw GIFEncodingError.noFrames }
            return AnimationExportReport(width: first.image.width, height: first.image.height,
                                         byteCount: lastSize, frameRate: timeline.frameRate / Double(step))
        }
        throw AnimationExportError.gifTooLarge(lastSize)
    }

    nonisolated private static func downsample(_ frames: [GIFFrame], step: Int) -> [GIFFrame] {
        guard step > 1, frames.count > 1 else { return frames }
        var indices = Swift.stride(from: 0, to: frames.count, by: step).map { $0 }
        if indices.last != frames.count - 1 { indices.append(frames.count - 1) }
        return indices.enumerated().map { position, index in
            let end = position + 1 < indices.count ? indices[position + 1] : frames.count
            let delay = frames[index..<end].reduce(0) { $0 + $1.delay }
            return GIFFrame(image: frames[index].image, delay: delay)
        }
    }
}

private struct AnimationExportReport: Sendable {
    let width: Int
    let height: Int
    let byteCount: Int
    let frameRate: Double
}

private enum AnimationExportError: Error, CustomStringConvertible {
    case resizeFailed
    case gifTooLarge(Int)

    var description: String {
        switch self {
        case .resizeFailed: "无法将 GIF 帧缩放到 900 px"
        case let .gifTooLarge(bytes): "GIF 降帧后仍超过 3 MB（\(bytes) 字节）"
        }
    }
}

private struct SnapshotAnimationScene: View {
    let store: IslandStore
    let notch: NotchMetrics
    let frame: SnapshotAnimationFrame
    let expandedSize: CGSize
    let now: Date
    private var canvasWidth: CGFloat { max(720, expandedSize.width + 120) }

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.12, green: 0.16, blue: 0.22),
                                    Color(red: 0.065, green: 0.09, blue: 0.14),
                                    Color(red: 0.14, green: 0.11, blue: 0.17)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(.white.opacity(0.065)).frame(height: 33)
            IslandRootView(store: store, notch: notch, mode: frame.presentation.mode,
                           now: now, animated: false, animationsVisible: false,
                           previewPresentation: frame.presentation,
                           previewContentProgress: frame.contentProgress)
        }
        .frame(width: canvasWidth, height: 460)
        .environment(\.colorScheme, .dark)
    }
}
