import Foundation
import Darwin

/// Match getcwd/FSEvents without Foundation's /private path alias rewriting.
/// A missing, inaccessible or cyclic path keeps its input spelling; no retries.
func physicalPath(_ path: String) -> String {
    guard !path.utf8.contains(0), let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

func physicalURL(_ url: URL) -> URL {
    let path = physicalPath(url.path)
    guard path != url.path else { return url }
    return URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath)
}
