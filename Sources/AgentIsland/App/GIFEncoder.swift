import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct GIFFrame: Sendable {
    let image: CGImage
    let delay: TimeInterval
}

enum GIFEncoder {
    static func write(_ frames: [GIFFrame], to url: URL, loopCount: Int = 0) throws {
        guard !frames.isEmpty else { throw GIFEncodingError.noFrames }
        guard frames.allSatisfy({ $0.delay.isFinite && $0.delay > 0 }) else {
            throw GIFEncodingError.invalidDelay
        }
        let size = (frames[0].image.width, frames[0].image.height)
        guard frames.allSatisfy({ ($0.image.width, $0.image.height) == size }) else {
            throw GIFEncodingError.inconsistentDimensions
        }
        // UTType.gif is the warning-free modern spelling of the legacy kUTTypeGIF identifier.
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil
        ) else { throw GIFEncodingError.cannotCreateDestination }

        let fileProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]
        ] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)
        for frame in frames {
            // Build properties from scratch so source EXIF/XMP metadata is never propagated.
            let properties = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frame.delay]
            ] as CFDictionary
            CGImageDestinationAddImage(destination, frame.image, properties)
        }
        guard CGImageDestinationFinalize(destination) else { throw GIFEncodingError.finalizeFailed }
    }
}

enum GIFEncodingError: Error, CustomStringConvertible {
    case noFrames, invalidDelay, inconsistentDimensions, cannotCreateDestination, finalizeFailed

    var description: String {
        switch self {
        case .noFrames: "GIF 没有可编码的帧"
        case .invalidDelay: "GIF 帧延迟必须是正的有限秒数"
        case .inconsistentDimensions: "GIF 的所有帧必须尺寸一致"
        case .cannotCreateDestination: "无法创建 GIF 输出"
        case .finalizeFailed: "GIF 编码失败"
        }
    }
}
