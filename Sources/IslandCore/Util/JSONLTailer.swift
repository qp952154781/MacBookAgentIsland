import Foundation
import Darwin

public actor JSONLTailer {
    public let url: URL
    // Historical Codex tool output can contain multi-megabyte valid JSON records.
    public static let maximumLineBytes = 16 * 1_048_576
    public private(set) var skippedLines = 0
    public private(set) var hasMore = false
    public private(set) var wasTruncated = false
    public private(set) var bytesReadTotal = 0
    public private(set) var lastReadSucceeded = false
    private let initialTailBytes: Int?
    private var identity: String?
    private var offset: UInt64 = 0
    private var pending = Data()
    private var discardPartialLine = false

    public init(url: URL, initialTailBytes: Int? = nil) {
        self.url = url
        self.initialTailBytes = initialTailBytes.map { max(0, $0) }
    }

    /// Returns complete lines without LF/CRLF. Missing files and IO errors are retryable on the next signal.
    /// Malformed JSON remains a single independent line for the provider to skip.
    public func readNewLines(maximumReadBytes: Int = Int.max) -> [Data] {
        autoreleasepool { readBatch(maximumReadBytes: maximumReadBytes) }
    }

    private func readBatch(maximumReadBytes: Int) -> [Data] {
        hasMore = false
        lastReadSucceeded = false
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0, info.st_size >= 0 else { return [] }
            let newIdentity = "\(info.st_dev):\(info.st_ino)"
            let size = UInt64(info.st_size)
            if newIdentity != identity || size < offset {
                skippedLines = 0
                wasTruncated = identity != nil
                offset = 0
                pending = Data()
                discardPartialLine = false
                if let initialTailBytes, size > UInt64(initialTailBytes) {
                    offset = size - UInt64(initialTailBytes)
                    try handle.seek(toOffset: offset - 1)
                    let preceding = try handle.read(upToCount: 1)
                    discardPartialLine = preceding?.first != 10
                }
            }
            identity = newIdentity
            try handle.seek(toOffset: offset)
            var lines: [Data] = []
            let batchStart = offset
            while offset - batchStart < UInt64(max(1, maximumReadBytes)), let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                offset += UInt64(chunk.count)
                bytesReadTotal += chunk.count
                let previouslyScanned = pending.count
                pending.append(chunk)
                var lineStart = pending.startIndex
                let scanStart = pending.index(pending.startIndex, offsetBy: previouslyScanned)
                // Scan each byte once, including when a partial line spans multiple chunks or reads.
                for newline in scanStart..<pending.endIndex where pending[newline] == 10 {
                    let lineRange = lineStart..<newline
                    lineStart = pending.index(after: newline)
                    if discardPartialLine {
                        discardPartialLine = false
                        continue
                    }
                    guard lineRange.count <= Self.maximumLineBytes else { skippedLines += 1; continue }
                    var line = Data(pending[lineRange])
                    if line.last == 13 { line.removeLast() }
                    if !line.isEmpty {
                        if String(data: line, encoding: .utf8) != nil { lines.append(line) }
                        else { skippedLines += 1 }
                    }
                }
                if lineStart != pending.startIndex { pending = Data(pending[lineStart...]) }
                if pending.count > Self.maximumLineBytes || discardPartialLine {
                    if !discardPartialLine { skippedLines += 1 }
                    pending = Data()
                    discardPartialLine = true
                }
            }
            hasMore = offset < size
            lastReadSucceeded = true
            return lines
        } catch {
            return []
        }
    }
}
