import Darwin
import Foundation

nonisolated struct DirectoryUsage: Sendable, Equatable {
    var bytes: Int64 = 0
    var unreadableFolders = 0
    var isReadable = true
}

/// Allocated size like `du -x`: symlinks not followed, other volumes not entered,
/// hard links counted once. Dataless iCloud files have no blocks, so they count as 0.
nonisolated enum DirectorySizer {
    static func usage(
        of url: URL,
        excluding excluded: Set<String> = [],
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> DirectoryUsage {
        var usage = DirectoryUsage()
        let path = strdup(url.path)
        defer { free(path) }
        var argv: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else {
            usage.isReadable = false
            return usage
        }
        defer { fts_close(stream) }

        var linkedInodes = Set<UInt64>()
        var visited = 0
        while let entry = fts_read(stream) {
            visited += 1
            if visited % 2048 == 0, isCancelled() { break }
            let level = entry.pointee.fts_level
            switch Int32(entry.pointee.fts_info) {
            case FTS_DP:
                continue
            case FTS_DNR, FTS_ERR, FTS_NS:
                usage.unreadableFolders += 1
                if level == 0 { usage.isReadable = false }
                continue
            case FTS_D where level > 0 && !excluded.isEmpty:
                if excluded.contains(String(cString: entry.pointee.fts_path)) {
                    fts_set(stream, entry, FTS_SKIP)
                    continue
                }
            default:
                break
            }
            guard let stat = entry.pointee.fts_statp?.pointee else { continue }
            if stat.st_nlink > 1, (stat.st_mode & S_IFMT) != S_IFDIR, !linkedInodes.insert(stat.st_ino).inserted {
                continue
            }
            usage.bytes += Int64(stat.st_blocks) * 512
        }
        return usage
    }
}

/// Runs blocking file-system work on its own threads: a folder waiting on a privacy prompt
/// or a slow external disk must not hold a Swift concurrency thread.
nonisolated enum BlockingIO {
    private static let queue = DispatchQueue(label: "Vrac.BlockingIO", qos: .utility, attributes: .concurrent)

    static func run<T: Sendable>(_ work: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) -> T) async -> T {
        let flag = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: work(flag.isSet)) }
            }
        } onCancel: {
            flag.set()
        }
    }
}

private nonisolated final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    @Sendable func isSet() -> Bool { lock.withLock { value } }
}
