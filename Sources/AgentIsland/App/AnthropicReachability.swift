import Foundation
import SystemConfiguration
import IslandCore

/// SCNetworkReachability only asks the system routing service; it sends no network traffic.
struct AnthropicReachability: ClaudeReachabilityChecking {
    func isReachable() async -> Bool {
        guard let target = SCNetworkReachabilityCreateWithName(nil, "api.anthropic.com") else { return false }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(target, &flags), flags.contains(.reachable) else { return false }
        if !flags.contains(.connectionRequired) { return true }
        let canConnectAutomatically = flags.contains(.connectionOnDemand) || flags.contains(.connectionOnTraffic)
        return canConnectAutomatically && !flags.contains(.interventionRequired)
    }
}
