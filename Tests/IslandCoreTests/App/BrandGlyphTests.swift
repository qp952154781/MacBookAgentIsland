import AppKit
import QuartzCore
import Testing
import IslandCore
@testable import AgentIsland

/// All assets are hand-drawn test pixels, never copied from installed applications.
private func glyphFixture(root: URL, app: String = "ChatGPT.app", name: String = "chatgptTemplate@2x.png",
                          width: Int = 36, modified: TimeInterval = 1000, padding: Int = 0) throws -> URL {
    let url = root.appendingPathComponent(app + "/Contents/Resources/" + name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: width,
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    for y in 0..<width {
        for x in 0..<width {
            let opaque = x >= padding && y >= padding && x < width - padding && y < width - padding
            bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: opaque ? 1 : 0), atX: x, y: y)
        }
    }
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path)
    return url
}

private func fixtureRoot() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(".build/brand-glyph-tests/" + UUID().uuidString, isDirectory: true)
}

@MainActor @Test func brandGlyphSearchPrefersTemplatesAcrossBothInstallLocations() async throws {
    let root = fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let system = root.appendingPathComponent("Applications"), user = root.appendingPathComponent("user/Applications")
    _ = try glyphFixture(root: system, name: "icon-codex-dark-color.png")
    let preferred = try glyphFixture(root: user)
    _ = try glyphFixture(root: system, app: "Claude.app", name: "TrayIconTemplate-Dark@2x.png", width: 48)
    let loader = BrandGlyphLoader(applicationDirectories: [system, user])
    await loader.refresh()
    let codex = try #require(loader.glyph(for: .codex))
    #expect(codex.key.path == preferred.path)
    #expect(codex.pointSize == CGSize(width: 18, height: 18))
    #expect(loader.glyph(for: .claude)?.pointSize == CGSize(width: 24, height: 24))
    let systemTemplate = try glyphFixture(root: system)
    await loader.refresh()
    #expect(loader.glyph(for: .codex)?.key.path == systemTemplate.path)
}

@MainActor @Test func brandGlyphCacheInvalidatesOnMtimeAndDeletionAndToleratesCorruption() async throws {
    let root = fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let primary = try glyphFixture(root: root)
    let secondary = try glyphFixture(root: root, name: "icon-codex-dark-color.png")
    let loader = BrandGlyphLoader(applicationDirectories: [root])
    await loader.refresh()
    let first = try #require(loader.glyph(for: .codex))
    await loader.refresh()
    #expect(loader.glyph(for: .codex) === first)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: primary.path)
    await loader.refresh()
    #expect(loader.glyph(for: .codex) !== first)
    try Data("broken hand-written fixture".utf8).write(to: primary)
    await loader.refresh()
    #expect(loader.glyph(for: .codex)?.key.path == secondary.path)
    try FileManager.default.removeItem(at: secondary)
    await loader.refresh()
    #expect(loader.glyph(for: .codex) == nil)
    #expect(loader.glyph(for: .claude) == nil)
    _ = try glyphFixture(root: root, modified: 3000)
    await loader.refresh()
    #expect(loader.glyph(for: .codex) != nil)
}

@MainActor @Test func officialGlyphLayerAnimatesCachedContentsAndClearsThemOnFallback() async throws {
    _ = NSApplication.shared
    let root = fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try glyphFixture(root: root)
    let loader = BrandGlyphLoader(applicationDirectories: [root])
    await loader.refresh()
    let glyph = try #require(loader.glyph(for: .codex))
    let view = IndicatorView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    for (kind, duration, keyPath) in [(LayerAnimationView.Kind.codex, 8.0, "transform.rotation.z"), (.claude, 8.0, "transform.rotation.z")] {
        view.configure(kind: kind, color: NSColor.white.cgColor, running: true, glyph: glyph)
        let mark = try #require(view.layer?.sublayers?.last)
        #expect(mark.opacity == 1)
        #expect(mark.anchorPoint == CGPoint(x: 0.5, y: 0.5))
        #expect(mark.position == CGPoint(x: 7, y: 7))
        #expect(mark.mask == nil)
        #expect(mark.backgroundColor == nil)
        let contents = try #require(glyph.raster(size: view.bounds.size, scale: window.backingScaleFactor,
                                                tint: NSColor.white.cgColor))
        #expect((mark.contents as AnyObject?) === contents)
        #expect(contents.width == Int(14 * window.backingScaleFactor))
        let renders = glyph.rasterizations
        for _ in 0..<20 {
            view.configure(kind: kind, color: NSColor.white.cgColor, running: true, glyph: glyph)
            view.layout()
            #expect((mark.contents as AnyObject?) === contents)
        }
        #expect(glyph.rasterizations == renders)
        #expect(loader.bitmapDecodes == 1)
        let animation = try #require(mark.animation(forKey: "activity") as? CAKeyframeAnimation)
        #expect(animation.keyPath == keyPath)
        #expect(animation.calculationMode == .discrete)
        #expect(animation.duration == duration)
        #expect(animation.values?.count == Int(duration * 10) + 1)
        view.stop()
        #expect(mark.animationKeys()?.isEmpty != false)
        view.configure(kind: kind, color: NSColor.white.cgColor, running: false, glyph: glyph)
        #expect((mark.contents as AnyObject?) === contents)
        #expect(glyph.rasterizations == renders)
        #expect(mark.animationKeys()?.isEmpty != false)
        #expect(view.frame.size == CGSize(width: 14, height: 14))
    }
    view.configure(kind: .codex, color: NSColor.white.cgColor, running: false)
    let mark = try #require(view.layer?.sublayers?.last as? CAShapeLayer)
    #expect(mark.mask == nil)
    #expect(mark.contents == nil)
    #expect(mark.backgroundColor == nil)
    #expect(mark.path != nil)
}

@MainActor @Test func brandGlyphNormalizesPaddingAndRejectsInvisibleAssets() async throws {
    let root = fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try glyphFixture(root: root, padding: 6)
    let loader = BrandGlyphLoader(applicationDirectories: [root])
    await loader.refresh()
    let glyph = try #require(loader.glyph(for: .codex))
    #expect(glyph.bitmap.width == 24 && glyph.bitmap.height == 24)
    #expect(glyph.pointSize == CGSize(width: 12, height: 12))
    _ = try glyphFixture(root: root, modified: 2000, padding: 36)
    await loader.refresh()
    #expect(loader.glyph(for: .codex) == nil)
}

@MainActor @Test func glyphRasterCacheKeysIncludePixelsScaleAndTint() async throws {
    let root = fixtureRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try glyphFixture(root: root)
    let loader = BrandGlyphLoader(applicationDirectories: [root])
    await loader.refresh()
    let glyph = try #require(loader.glyph(for: .codex))
    let size = CGSize(width: 14, height: 14)
    let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor
    let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).cgColor
    let first = try #require(glyph.raster(size: size, scale: 2, tint: red))
    #expect(first.width == 28 && first.height == 28)
    for _ in 0..<100 {
        #expect(glyph.raster(size: size, scale: 2, tint: red) === first)
    }
    #expect(glyph.rasterizations == 1 && glyph.cacheHits == 100)
    let triple = try #require(glyph.raster(size: size, scale: 3, tint: red))
    #expect(triple.width == 42 && triple.height == 42)
    #expect(triple !== first)
    // Equal pixel dimensions at a different scale still need different padding.
    #expect(glyph.raster(size: CGSize(width: 28, height: 28), scale: 1, tint: red) !== first)
    let tinted = try #require(glyph.raster(size: size, scale: 2, tint: green))
    #expect(tinted !== first)
    // Check cached sRGB bytes directly, without display-profile conversion by AppKit.
    let data = try #require(tinted.dataProvider?.data)
    let pixels = try #require(CFDataGetBytePtr(data))
    let center = 14 * tinted.bytesPerRow + 14 * 4
    #expect(pixels[center] == 0 && pixels[center + 1] == 255 && pixels[center + 2] == 0 && pixels[center + 3] == 255)
    #expect(pixels[3] == 0)
    await loader.refresh()
    #expect(loader.bitmapDecodes == 1)
    #expect(loader.glyph(for: .codex) === glyph)
    _ = try glyphFixture(root: root, modified: 2000)
    await loader.refresh()
    #expect(loader.bitmapDecodes == 2)
    let changed = try #require(loader.glyph(for: .codex))
    #expect(changed.raster(size: size, scale: 2, tint: red) !== first)
}

@MainActor @Test func fallbackRotationAndActivityStayInsideTheirBounds() throws {
    _ = NSApplication.shared
    let view = IndicatorView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    for size in [13.0, 14.0] {
        view.setFrameSize(CGSize(width: size, height: size))
        for kind in [LayerAnimationView.Kind.claude, .codex] {
            view.configure(kind: kind, color: NSColor.white.cgColor, running: true)
            let mark = try #require(view.layer?.sublayers?.last as? CAShapeLayer)
            let animation = try #require(mark.animation(forKey: "activity") as? CAKeyframeAnimation)
            #expect(animation.keyPath == "transform.rotation.z")
            #expect(animation.duration == 8 && mark.opacity == 1)
            let outline = try #require(mark.path).copy(strokingWithWidth: mark.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 0)
            for angle in try #require(animation.values as? [Double]) {
                var transform = CGAffineTransform(translationX: size / 2, y: size / 2)
                    .rotated(by: angle).translatedBy(x: -size / 2, y: -size / 2)
                let rotated = try #require(outline.copy(using: &transform))
                #expect(view.bounds.contains(rotated.boundingBoxOfPath))
            }
        }
    }
    for width in [14.0, 18.0, 28.0] {
        view.setFrameSize(CGSize(width: width, height: 2))
        view.configure(kind: .activity(nil), color: NSColor.white.cgColor, running: true)
        let mark = try #require(view.layer?.sublayers?.last as? CAShapeLayer)
        let slider = try #require(mark.path).boundingBoxOfPath
        #expect(abs(slider.width - max(5, width * 0.30)) < 0.0001)
        let animation = try #require(mark.animation(forKey: "activity") as? CAKeyframeAnimation)
        for translation in try #require(animation.values as? [Double]) {
            #expect(translation >= 0 && translation + slider.width <= width + 0.0001)
        }
        for fraction in [0.0, 3.0 / 7, 1.0] {
            view.configure(kind: .activity(fraction), color: NSColor.white.cgColor, running: false)
            #expect(abs((mark.path?.boundingBoxOfPath.width ?? 0) - width * fraction) < 0.0001)
            #expect(mark.animationKeys()?.isEmpty != false)
        }
    }
}
