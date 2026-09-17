import Foundation

/// Positional provider lookup for the existing wings and column labels.
public enum ProviderLayout {
    public static func provider(at index: Int, in orderedIDs: [ProviderID] = ProviderRegistry.orderedIDs) -> ProviderID? {
        guard orderedIDs.indices.contains(index) else { return nil }
        return orderedIDs[index]
    }

    public static func wings(in orderedIDs: [ProviderID] = ProviderRegistry.orderedIDs) -> (left: ProviderID?, right: ProviderID?) {
        (provider(at: 0, in: orderedIDs), provider(at: 1, in: orderedIDs))
    }
}
