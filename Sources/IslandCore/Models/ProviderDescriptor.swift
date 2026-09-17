import Foundation

/// UI-independent presentation metadata; conversion to platform colors happens in the app.
public struct ProviderDescriptor: Equatable, Sendable, Identifiable {
    public struct RGB: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red; self.green = green; self.blue = blue
        }
    }

    public enum BuiltInIcon: Equatable, Sendable { case claude, codex, generic }

    public enum IconSource: Equatable, Sendable {
        case builtIn(BuiltInIcon)
        case installedApplication(bundleName: String, resourceNames: [String], fallback: BuiltInIcon)
        case applicationPath(String)
        case none

        public var fallback: BuiltInIcon {
            switch self {
            case let .builtIn(icon), let .installedApplication(_, _, icon): icon
            case .none, .applicationPath: .generic
            }
        }
    }

    public let id: ProviderID
    public let displayName: String
    public let brandColor: RGB
    public let glyphColor: RGB
    public let iconSource: IconSource
    public let hasQuota: Bool
    public let hasSessions: Bool

    public init(id: ProviderID, displayName: String, brandColor: RGB, glyphColor: RGB? = nil,
                iconSource: IconSource, hasQuota: Bool, hasSessions: Bool) {
        self.id = id; self.displayName = displayName; self.brandColor = brandColor
        self.glyphColor = glyphColor ?? brandColor; self.iconSource = iconSource
        self.hasQuota = hasQuota; self.hasSessions = hasSessions
    }
}
