import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Original geometric artwork; no external assets or brand logos.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Cannot create icon context")
        }
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        context.setFillColor(CGColor(red: 0.13, green: 0.15, blue: 0.19, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
                               cornerWidth: 200, cornerHeight: 200, transform: nil))
        context.fillPath()
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 150, y: 330, width: 724, height: 364),
                               cornerWidth: 182, cornerHeight: 182, transform: nil))
        context.fillPath()
        for (x, color) in [(CGFloat(322), CGColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)),
                           (CGFloat(594), CGColor(red: 0.54, green: 0.71, blue: 1, alpha: 1))] {
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: x, y: 458, width: 108, height: 108))
        }
        let suffix = scale == 2 ? "@2x" : ""
        let file = directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("Cannot encode icon")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Cannot save icon") }
    }
}

// Some sandboxed macOS sessions cannot reach the system ICNS encoder.
// Preserve the same PNG representations in the documented ICNS chunk container.
func bigEndian(_ value: Int) -> Data {
    var word = UInt32(value).bigEndian
    return withUnsafeBytes(of: &word) { Data($0) }
}
let representations = [("icp4", "16x16"), ("icp5", "32x32"), ("ic07", "128x128"),
                       ("ic08", "256x256"), ("ic09", "512x512"), ("ic11", "16x16@2x"),
                       ("ic12", "32x32@2x"), ("ic13", "128x128@2x"),
                       ("ic14", "256x256@2x"), ("ic10", "512x512@2x")]
var chunks = Data()
for (type, name) in representations {
    let png = try Data(contentsOf: directory.appendingPathComponent("icon_\(name).png"))
    chunks.append(Data(type.utf8))
    chunks.append(bigEndian(png.count + 8))
    chunks.append(png)
}
try (Data("icns".utf8) + bigEndian(chunks.count + 8) + chunks)
    .write(to: directory.deletingLastPathComponent().appendingPathComponent("AppIcon-fallback.icns"), options: .atomic)
