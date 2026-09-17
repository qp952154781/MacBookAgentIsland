import Foundation

public enum ExecutableLocator {
    public static func codexCLI(environment: [String: String] = ProcessInfo.processInfo.environment,
                                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                                existenceOnly: Bool = false, homeOnly: Bool = false) async -> URL? {
        let home = homeDirectory.path
        var candidates = [environment["AGENT_ISLAND_CODEX_PATH"],
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex", "\(home)/.npm-global/bin/codex"
        ].compactMap { $0 }
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        if homeOnly { candidates = candidates.filter { $0.hasPrefix(home + "/") } }
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return physicalURL(URL(fileURLWithPath: path))
        }
        guard !existenceOnly && !homeOnly else { return nil }
        return await loginShellPath(command: "codex", environment: environment)
    }

    public static func claudeCLI(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) async -> URL? {
        let root = homeDirectory.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for version in versions.filter({ semanticVersion($0) != nil }).sorted(by: { compareVersions($0, $1) == .orderedDescending }) {
            let url = root.appendingPathComponent("\(version)/claude.app/Contents/MacOS/claude")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return await loginShellPath(command: "claude", environment: environment)
    }

    private static func loginShellPath(command: String, environment: [String: String]) async -> URL? {
        // command is an internal constant, never user-controlled shell input.
        guard let result = try? await ProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lc", "command -v \(command)"], timeout: 3, environment: environment), result.exitCode == 0,
            let text = String(data: result.stdout, encoding: .utf8) else { return nil }
        for path in text.split(separator: "\n").reversed().map(String.init) {
            if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    private static func semanticVersion(_ value: String) -> (numbers: [Int], prerelease: [String])? {
        let withoutMetadata = value.split(separator: "+", maxSplits: 1).first.map(String.init) ?? ""
        let parts = withoutMetadata.split(separator: "-", maxSplits: 1)
        guard let core = parts.first else { return nil }
        let components = core.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = components.compactMap { Int($0) }
        guard !numbers.isEmpty, numbers.count == components.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        let prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        return (numbers, prerelease)
    }

    /// Numeric components, release > prerelease, numeric prerelease identifiers < textual identifiers.
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let left = semanticVersion(lhs), let right = semanticVersion(rhs) else {
            return lhs.compare(rhs, options: .numeric)
        }
        for index in 0..<max(left.numbers.count, right.numbers.count) {
            let l = index < left.numbers.count ? left.numbers[index] : 0
            let r = index < right.numbers.count ? right.numbers[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        if left.prerelease.isEmpty != right.prerelease.isEmpty {
            return left.prerelease.isEmpty ? .orderedDescending : .orderedAscending
        }
        for (l, r) in zip(left.prerelease, right.prerelease) where l != r {
            switch (Int(l), Int(r)) {
            case let (a?, b?): return a < b ? .orderedAscending : .orderedDescending
            case (_?, nil): return .orderedAscending
            case (nil, _?): return .orderedDescending
            default: return l.compare(r)
            }
        }
        if left.prerelease.count == right.prerelease.count { return .orderedSame }
        return left.prerelease.count < right.prerelease.count ? .orderedAscending : .orderedDescending
    }
}
