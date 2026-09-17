import Foundation

public enum ProviderRegistry {
    /// Presentation order is explicit and independent of IDs or dictionary iteration order.
    public static let ordered: [ProviderDescriptor] = [
        ProviderDescriptor(id: .claude, displayName: "Claude",
            brandColor: .init(red: 0.851, green: 0.467, blue: 0.341),
            iconSource: .installedApplication(bundleName: "Claude.app",
                resourceNames: ["TrayIconTemplate@2x.png", "TrayIconTemplate-Dark@2x.png"], fallback: .claude),
            hasQuota: true, hasSessions: true),
        ProviderDescriptor(id: .codex, displayName: "Codex",
            brandColor: .init(red: 0.541, green: 0.706, blue: 1),
            glyphColor: .init(red: 232.0 / 255, green: 234.0 / 255, blue: 240.0 / 255),
            iconSource: .installedApplication(bundleName: "ChatGPT.app",
                resourceNames: ["chatgptTemplate@2x.png", "icon-codex-dark-color.png"], fallback: .codex),
            hasQuota: true, hasSessions: true)
    ]
    public static let orderedIDs: [ProviderID] = ordered.map(\.id)

    /// Unknown identities remain representable without inheriting another provider's branding.
    public static func descriptor(for id: ProviderID) -> ProviderDescriptor {
        if let descriptor = ordered.first(where: { $0.id == id }) { return descriptor }
        return ProviderDescriptor(id: id, displayName: id.rawValue,
            brandColor: .init(red: 0.7, green: 0.7, blue: 0.7), iconSource: .none,
            hasQuota: false, hasSessions: false)
    }
}
