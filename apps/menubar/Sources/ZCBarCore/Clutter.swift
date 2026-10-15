import CryptoKit
import Foundation

/// Files with the same bytes in more than one place, for My Clutter.
public struct DuplicateGroup: Codable, Sendable, Equatable, Identifiable {
    public var files: [LargeFile]
    /// Each copy's size; the copies past the first are what it wastes.
    public var size: Int64

    public var id: String { files.map(\.id).joined(separator: "\n") }
    public var wasted: Int64 { size * Int64(max(files.count - 1, 0)) }
}

public enum Duplicates {
    /// Same-size files first, the cheap test, then their SHA-256: hashing
    /// runs only where sizes collide. Biggest waste first.
    public static func groups(paths: [String], home: String, minimum: Int64) -> [DuplicateGroup] {
        let candidates = LargeFiles.candidates(paths: paths, home: home, minimum: minimum)
        var bySize: [Int64: [LargeFile]] = [:]
        for file in candidates {
            let length = (try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            bySize[Int64(length), default: []].append(file)
        }
        var groups: [DuplicateGroup] = []
        for (size, files) in bySize where files.count > 1 && size > 0 {
            var byHash: [String: [LargeFile]] = [:]
            for file in files {
                if let hash = sha256(file.url) { byHash[hash, default: []].append(file) }
            }
            for same in byHash.values where same.count > 1 {
                groups.append(DuplicateGroup(files: same.sorted { $0.id < $1.id }, size: size))
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum OldDownloads {
    /// What sat in the folder for longer than `days`, by when it arrived:
    /// a download keeps the date its server gave it as its modified date.
    public static func files(in folder: URL, olderThan days: Int = 30, now: Date = .now) -> [LargeFile] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                options: [.skipsHiddenFiles])) ?? []
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        return all.compactMap { url -> LargeFile? in
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard let added = v?.addedToDirectoryDate ?? v?.contentModificationDate, added < cutoff else { return nil }
            return LargeFile(url: url, size: DiskUsage.allocated(url), modified: added)
        }
        .sorted { $0.size > $1.size }
    }
}
