import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AgentIsland

@Test func snapshotAnimationFramePlanMatchesTimelineAndMotionCurves() throws {
    let timeline = SnapshotAnimationTimeline()
    let collapsed = CGSize(width: 170, height: 31)
    let expanded = CGSize(width: 760, height: 400)
    let frames = SnapshotAnimationFramePlan.make(
        timeline: timeline, collapsedSize: collapsed, expandedSize: expanded
    )

    #expect(frames.count == 75)
    #expect(frames.count == timeline.frameCount)
    #expect(abs((try #require(frames.last)).time + timeline.frameDuration - timeline.duration) < 0.000_001)
    #expect(frames.first?.presentation.size == collapsed)
    #expect(frames.last?.presentation.size == collapsed)
    #expect(frames.first?.contentProgress == 0)
    #expect(frames.last?.contentProgress == 0)

    let expansion = frames.filter { $0.phase == .expand }.map(\.presentation.size.width)
    let peakIndex = try #require(expansion.indices.max(by: { expansion[$0] < expansion[$1] }))
    #expect(expansion[peakIndex] > expanded.width)
    #expect(zip(expansion[..<peakIndex], expansion.dropFirst()).allSatisfy { $0 <= $1 })
    #expect(expansion.last.map { $0 < expansion[peakIndex] } == true)

    let beforeDelay = frames.filter {
        $0.phase == .expand && $0.time - timeline.expandStart <= IslandMotion.contentAppearDelay
    }
    let afterDelay = frames.first {
        $0.phase == .expand && $0.time - timeline.expandStart > IslandMotion.contentAppearDelay
    }
    #expect(beforeDelay.allSatisfy { $0.contentProgress == 0 })
    #expect(try #require(afterDelay).contentProgress > 0)
}

@Test func gifEncoderWritesFramesLoopDelayAndNoSourceMetadata() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-island-gif-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("fixture.gif")
    let delays = [0.04, 0.08, 0.12, 0.16]
    let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0)]
    let frames = try zip(colors, delays).map { color, delay in
        GIFFrame(image: try solidImage(red: color.0, green: color.1, blue: color.2), delay: delay)
    }
    try GIFEncoder.write(frames, to: url)

    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    #expect(CGImageSourceGetCount(source) == frames.count)
    let global = try #require(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
    let gif = try #require(global[kCGImagePropertyGIFDictionary] as? [CFString: Any])
    #expect((gif[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue == 0)
    #expect(global[kCGImagePropertyExifDictionary] == nil)
    #expect(global.keys.allSatisfy { !String($0).localizedCaseInsensitiveContains("xmp") })
    for (index, delay) in delays.enumerated() {
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
        let frameGIF = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        let encodedDelay = try #require(frameGIF[kCGImagePropertyGIFDelayTime] as? NSNumber).doubleValue
        #expect(abs(encodedDelay - delay) < 0.005)
        #expect(properties[kCGImagePropertyExifDictionary] == nil)
        #expect(properties.keys.allSatisfy { !String($0).localizedCaseInsensitiveContains("xmp") })
    }
}

@Test func snapshotAnimationArgumentParsesAndIsMutuallyExclusive() throws {
    let options = try LaunchOptions(arguments: ["--snapshot-animation", "/fixture/animation"])
    #expect(options.snapshotAnimationDirectory == "/fixture/animation")
    #expect(LaunchOptions.helpText.contains("--snapshot-animation <目录>"))
    for arguments in [
        ["--snapshot-animation", "/fixture/animation", "--snapshot", "/fixture/snapshots"],
        ["--snapshot-animation", "/fixture/animation", "--dump", "system"],
        ["--snapshot-animation", "/fixture/animation", "--measure"],
        ["--snapshot-animation", "/fixture/animation", "--print-geometry"]
    ] {
        #expect(throws: LaunchOptions.ParseError.self) { try LaunchOptions(arguments: arguments) }
    }
}

private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: colorSpace,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    return try #require(context.makeImage())
}
