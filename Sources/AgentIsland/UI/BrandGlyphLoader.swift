import AppKit
import ImageIO
import Observation
import SwiftUI
import IslandCore

/// Only installed application resources are read. No asset is written or bundled.
@MainActor @Observable final class BrandGlyphLoader {
    static let shared = BrandGlyphLoader()
    private let files: BrandGlyphFiles
    private var glyphs: [ProviderID: Glyph] = [:]

    /// A decoded source owns a small, bounded cache shared by static and animated views.
    @MainActor final class Glyph {
        let key: BrandGlyphFiles.Key
        let bitmap: CGImage
        let pointSize: CGSize
        private var rasters: [RasterKey: CGImage] = [:]
        private(set) var rasterizations = 0
        private(set) var cacheHits = 0

        private struct RasterKey: Hashable {
            let width: Int
            let height: Int
            let scale: CGFloat
            let rgba: [CGFloat]
        }

        init(asset: BrandGlyphFiles.Asset) {
            key = asset.key; bitmap = asset.bitmap; pointSize = asset.pointSize
        }

        /// Bake scale and tint once. Animation only changes layer opacity/transform;
        /// no live mask, template tinting, or image decoding is needed by a frame.
        func raster(size: CGSize, scale: CGFloat, tint: CGColor) -> CGImage? {
            guard size.width.isFinite, size.height.isFinite, scale.isFinite, scale > 0,
                  size.width > 2, size.height > 2, size.width * scale <= 4096, size.height * scale <= 4096,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let color = tint.converted(to: space, intent: .defaultIntent, options: nil),
                  let rgba = color.components else { return nil }
            let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
            let key = RasterKey(width: width, height: height, scale: scale, rgba: rgba)
            if let cached = rasters[key] {
                cacheHits += 1
                UIRenderMetrics.glyphCacheHits += 1
                return cached
            }
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            let ratio = min((CGFloat(width) - 2 * scale) / CGFloat(bitmap.width),
                            (CGFloat(height) - 2 * scale) / CGFloat(bitmap.height))
            let target = CGSize(width: CGFloat(bitmap.width) * ratio, height: CGFloat(bitmap.height) * ratio)
            let rect = CGRect(x: (CGFloat(width) - target.width) / 2, y: (CGFloat(height) - target.height) / 2,
                              width: target.width, height: target.height)
            context.interpolationQuality = .high
            context.draw(bitmap, in: rect)
            context.setBlendMode(.sourceIn)
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let raster = context.makeImage() else { return nil }
            // Sizes/colors change only on presentation events; bound retention during resizes.
            if rasters.count >= 32 { rasters.removeAll(keepingCapacity: true) }
            rasters[key] = raster
            rasterizations += 1
            return raster
        }
    }

    @ObservationIgnored private(set) var bitmapDecodes: UInt64 = 0

    init(applicationDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    ]) {
        files = BrandGlyphFiles(applicationDirectories: applicationDirectories)
    }

    func glyph(for agent: ProviderID) -> Glyph? { glyphs[agent] }

    /// Revalidate on presentation/lifecycle events, never on an animation tick.
    func refresh() async {
        let loaded = await files.load()
        let decodes = await files.bitmapDecodes
        UIRenderMetrics.glyphBitmapDecodes += decodes - bitmapDecodes
        bitmapDecodes = decodes
        for agent in ProviderRegistry.orderedIDs {
            guard let asset = loaded[agent] else {
                if glyphs[agent] != nil { glyphs[agent] = nil }
                continue
            }
            guard glyphs[agent]?.key != asset.key else { continue }
            glyphs[agent] = Glyph(asset: asset)
        }
    }
}

/// Metadata checks, file reads and bitmap decoding stay off the UI executor.
actor BrandGlyphFiles {
    struct Key: Equatable, Sendable {
        let path: String
        let modified: Date
        let bytes: Int
    }
    struct Asset: Sendable {
        let key: Key
        let bitmap: CGImage
        let pointSize: CGSize
    }
    private struct Entry {
        let key: Key
        let asset: Asset?
    }
    private let applicationDirectories: [URL]
    private var cache: [String: Entry] = [:]
    private(set) var bitmapDecodes: UInt64 = 0

    init(applicationDirectories: [URL]) { self.applicationDirectories = applicationDirectories }

    func load() -> [ProviderID: Asset] {
        var result: [ProviderID: Asset] = [:]
        var visited = Set<String>()
        for descriptor in ProviderRegistry.ordered {
            let agent = descriptor.id
            guard case let .installedApplication(app, names, _) = descriptor.iconSource else { continue }
            // Prefer a template in either installation location over a secondary asset.
            search: for name in names {
                for directory in applicationDirectories {
                    let url = directory.appendingPathComponent(app + "/Contents/Resources/" + name)
                    visited.insert(url.path)
                    guard let attributes = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                          attributes.isRegularFile == true, let modified = attributes.contentModificationDate,
                          let bytes = attributes.fileSize, bytes > 0, bytes <= 16 * 1024 * 1024 else {
                        cache[url.path] = nil
                        continue
                    }
                    let key = Key(path: url.path, modified: modified, bytes: bytes)
                    if cache[url.path]?.key != key {
                        var asset: Asset?
                        if let data = try? Data(contentsOf: url),
                           let source = CGImageSourceCreateWithData(data as CFData, nil),
                           let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                            bitmapDecodes += 1
                            if let bitmap = Self.trimmingTransparentPadding(decoded) {
                                let scale: CGFloat = name.contains("@3x") ? 3 : name.contains("@2x") ? 2 : 1
                                asset = Asset(key: key, bitmap: bitmap,
                                              pointSize: CGSize(width: CGFloat(bitmap.width) / scale, height: CGFloat(bitmap.height) / scale))
                            }
                        }
                        cache[url.path] = Entry(key: key, asset: asset)
                    }
                    if let asset = cache[url.path]?.asset {
                        result[agent] = asset
                        break search
                    }
                }
            }
        }
        cache = cache.filter { visited.contains($0.key) }
        return result
    }

    /// Normalize optical bounds: the two menu bar templates contain different padding.
    /// Keep the original pixels; only transparent margins are cropped in memory.
    private static func trimmingTransparentPadding(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }
}

private struct BrandGlyphLoaderKey: EnvironmentKey {
    static let defaultValue: BrandGlyphLoader? = nil
}

extension EnvironmentValues {
    var brandGlyphLoader: BrandGlyphLoader? {
        get { self[BrandGlyphLoaderKey.self] }
        set { self[BrandGlyphLoaderKey.self] = newValue }
    }
}
