import Foundation

nonisolated struct RoomTrashItem: Hashable, Sendable {
    let url: URL
    let bytes: Int64
}

nonisolated struct RoomTrashFailure: Hashable, Sendable {
    let url: URL
    let reason: String
}

nonisolated struct RoomTrashResult: Sendable {
    var trashedURLs: [URL] = []
    var freedBytes: Int64 = 0
    var failures: [RoomTrashFailure] = []
}

/// Trash path for the rooms (Cleanup, Duplicates, Applications, Compress), which
/// work on paths they enumerate themselves rather than on a scan snapshot.
nonisolated enum RoomTrash {
    static func moveToTrash(
        _ items: [RoomTrashItem],
        blockReason: (URL) -> TrashSafetyBlockReason? = TrashSafetyPolicy.blockReason(for:),
        trashItem: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> RoomTrashResult {
        var result = RoomTrashResult()
        for item in items {
            if let reason = blockReason(item.url) {
                result.failures.append(RoomTrashFailure(
                    url: item.url,
                    reason: SystemIntegration.SystemIntegrationError.protectedTrashLocation(path: reason.path).localizedDescription
                ))
                continue
            }
            do {
                try trashItem(item.url)
                result.trashedURLs.append(item.url)
                result.freedBytes += item.bytes
            } catch {
                result.failures.append(RoomTrashFailure(url: item.url, reason: error.localizedDescription))
            }
        }
        return result
    }

    /// Allocated size of a file or folder, without following symlinks or crossing volumes.
    static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        guard values.isDirectory == true else {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let childValues = try? child.resourceValues(forKeys: keys),
                  childValues.isDirectory != true,
                  childValues.isSymbolicLink != true else { continue }
            total += Int64(childValues.totalFileAllocatedSize ?? childValues.fileAllocatedSize ?? 0)
        }
        return total
    }
}
