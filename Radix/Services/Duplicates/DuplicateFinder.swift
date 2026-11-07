import CryptoKit
import Foundation
import UniformTypeIdentifiers

nonisolated enum DuplicateKind: String, CaseIterable, Sendable {
    case images, videos, audio, documents, archives, other

    init(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            self = .other
            return
        }
        if type.conforms(to: .image) {
            self = .images
        } else if type.conforms(to: .audio) {
            self = .audio
        } else if type.conforms(to: .audiovisualContent) {
            self = .videos
        } else if type.conforms(to: .archive) || type.conforms(to: .diskImage) {
            self = .archives
        } else if type.conforms(to: .content) || type.conforms(to: .text) {
            self = .documents
        } else {
            self = .other
        }
    }
}

nonisolated struct DuplicateFile: Hashable, Sendable, Identifiable {
    let url: URL
    let size: Int64
    let modified: Date
    let created: Date?
    let device: UInt64
    let inode: UInt64
    var cloneID: CloneIdentity?

    var id: URL { url }

    /// Files with the same key share their data blocks: trashing one of them alone frees nothing.
    var storageKey: AnyHashable {
        cloneID.map(AnyHashable.init) ?? AnyHashable([device, inode])
    }

    init(url: URL, size: Int64, modified: Date, created: Date? = nil, device: UInt64 = 0, inode: UInt64, cloneID: CloneIdentity? = nil) {
        self.url = url
        self.size = size
        self.modified = modified
        self.created = created
        self.device = device
        self.inode = inode
        self.cloneID = cloneID
    }

    init(url: URL, status: stat) {
        self.init(
            url: url,
            size: Int64(status.st_size),
            modified: Self.date(status.st_mtimespec),
            created: status.st_birthtimespec.tv_sec > 0 ? Self.date(status.st_birthtimespec) : nil,
            device: UInt64(truncatingIfNeeded: status.st_dev),
            inode: UInt64(status.st_ino)
        )
    }

    /// True when the file is still a regular file with the size and date it had when it was compared.
    var isUnchanged: Bool {
        guard let status = Self.status(at: url), status.st_mode & S_IFMT == S_IFREG else { return false }
        return Int64(status.st_size) == size && Self.date(status.st_mtimespec) == modified
    }

    static func status(at url: URL) -> stat? {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &status)
        }
        return result == 0 ? status : nil
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }
}

nonisolated struct DuplicateGroup: Hashable, Sendable, Identifiable {
    let id: String
    let size: Int64
    var files: [DuplicateFile]

    init(files: [DuplicateFile]) {
        id = files.map(\.url.path).min() ?? ""
        size = files.first?.size ?? 0
        self.files = files
    }

    var name: String { files.first?.url.lastPathComponent ?? "" }
    var kind: DuplicateKind { files.first.map { DuplicateKind(url: $0.url) } ?? .other }
    var reclaimableBytes: Int64 { size * Int64(max(Set(files.map(\.storageKey)).count - 1, 0)) }

    func sharesStorage(_ file: DuplicateFile) -> Bool {
        file.cloneID != nil && files.contains { $0.url != file.url && $0.storageKey == file.storageKey }
    }
}

nonisolated struct DuplicateScanOptions: Sendable {
    var roots: [URL]
    var minimumSize: Int64 = 1_000_000
    var includesLibrary = false
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
}

nonisolated struct DuplicateScanProgress: Sendable, Equatable {
    enum Phase: Sendable { case listing, sampling, hashing, confirming }

    var phase: Phase = .listing
    var filesSeen = 0
    var candidates = 0
    var bytesToHash: Int64 = 0
    var bytesHashed: Int64 = 0
}

nonisolated struct DuplicateScanResult: Sendable {
    var groups: [DuplicateGroup] = []
    var filesSeen = 0
    var unreadableCount = 0
}

/// Lists files, groups them by size, then by a hash of their first and last 64 KB,
/// then by a full SHA-256, and finally confirms each group byte for byte.
nonisolated enum DuplicateFinder {
    static let sampleLength = 64 * 1024
    private static let chunkLength = 1 << 20
    private static let parallelReads = 4

    @concurrent
    static func scan(
        _ options: DuplicateScanOptions,
        progress report: @escaping @Sendable (DuplicateScanProgress) -> Void = { _ in }
    ) async throws -> DuplicateScanResult {
        var progress = DuplicateScanProgress()
        var unreadable = 0
        let files = try listFiles(options, progress: &progress, unreadable: &unreadable, report: report)

        var buckets = Dictionary(grouping: files, by: \.size).values.filter { $0.count > 1 }.map(Array.init)
        progress.candidates = buckets.reduce(0) { $0 + $1.count }
        progress.phase = .sampling
        report(progress)
        buckets = try await refine(buckets, progress: &progress, unreadable: &unreadable, report: report, digest: partialDigest)

        progress.phase = .hashing
        progress.bytesToHash = buckets.joined().reduce(0) { $0 + $1.size }
        report(progress)
        buckets = try await refine(buckets, progress: &progress, unreadable: &unreadable, report: report, digest: fullDigest)

        progress.phase = .confirming
        report(progress)
        var groups: [DuplicateGroup] = []
        try await forEachConcurrently(buckets, transform: confirmedGroup) { files in
            if files.count > 1 { groups.append(DuplicateGroup(files: files)) }
        }
        groups.sort { ($0.reclaimableBytes, $0.size, $1.id) > ($1.reclaimableBytes, $1.size, $0.id) }
        return DuplicateScanResult(groups: groups, filesSeen: progress.filesSeen, unreadableCount: unreadable)
    }

    private static func listFiles(
        _ options: DuplicateScanOptions,
        progress: inout DuplicateScanProgress,
        unreadable: inout Int,
        report: (DuplicateScanProgress) -> Void
    ) throws -> [DuplicateFile] {
        let library = DuplicateFile.status(at: options.home.appending(path: "Library")).map { [Int64($0.st_dev), Int64($0.st_ino)] }
        var seenInodes: Set<[UInt64]> = []
        var files: [DuplicateFile] = []
        for root in options.roots {
            guard let rootStatus = DuplicateFile.status(at: root.standardizedFileURL) else {
                unreadable += 1
                continue
            }
            let errors = ErrorCounter()
            guard let enumerator = FileManager.default.enumerator(
                at: root.standardizedFileURL,
                includingPropertiesForKeys: [],
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in errors.count += 1; return true }
            ) else { continue }

            for case let url as URL in enumerator {
                guard let status = DuplicateFile.status(at: url) else {
                    unreadable += 1
                    continue
                }
                let hidden = url.lastPathComponent.hasPrefix(".") || status.st_flags & UInt32(UF_HIDDEN) != 0
                switch status.st_mode & S_IFMT {
                case S_IFDIR:
                    let isLibrary = [Int64(status.st_dev), Int64(status.st_ino)] == library
                    if status.st_dev != rootStatus.st_dev || (isLibrary ? !options.includesLibrary : hidden) {
                        enumerator.skipDescendants()
                    }
                case S_IFREG:
                    progress.filesSeen += 1
                    if progress.filesSeen % 2_000 == 0 {
                        try Task.checkCancellation()
                        report(progress)
                    }
                    guard !hidden,
                          Int64(status.st_size) >= max(options.minimumSize, 1),
                          !ScanMetadataLoader.isDataless(fileFlags: status.st_flags),
                          seenInodes.insert([UInt64(truncatingIfNeeded: status.st_dev), UInt64(status.st_ino)]).inserted
                    else { continue }
                    files.append(DuplicateFile(url: url, status: status))
                default:
                    continue
                }
            }
            unreadable += errors.count
        }
        return files
    }

    private struct DigestKey: Hashable {
        let size: Int64
        let digest: SHA256Digest
    }

    private static func refine(
        _ buckets: [[DuplicateFile]],
        progress: inout DuplicateScanProgress,
        unreadable: inout Int,
        report: (DuplicateScanProgress) -> Void,
        digest: @escaping @Sendable (DuplicateFile) -> SHA256Digest?
    ) async throws -> [[DuplicateFile]] {
        var keyed: [DigestKey: [DuplicateFile]] = [:]
        var lastReport = ContinuousClock.now
        try await forEachConcurrently(Array(buckets.joined()), transform: { ($0, digest($0)) }) { file, value in
            if let value {
                keyed[DigestKey(size: file.size, digest: value), default: []].append(file)
            } else {
                unreadable += 1
            }
            if progress.phase == .hashing { progress.bytesHashed += file.size }
            if ContinuousClock.now - lastReport > .milliseconds(100) {
                lastReport = .now
                report(progress)
            }
        }
        return keyed.values.filter { $0.count > 1 }
    }

    static func partialDigest(_ file: DuplicateFile) -> SHA256Digest? {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        do {
            var hash = SHA256()
            hash.update(data: try handle.read(upToCount: sampleLength) ?? Data())
            if file.size > Int64(sampleLength) {
                try handle.seek(toOffset: UInt64(max(Int64(sampleLength), file.size - Int64(sampleLength))))
                hash.update(data: try handle.read(upToCount: sampleLength) ?? Data())
            }
            return hash.finalize()
        } catch {
            return nil
        }
    }

    static func fullDigest(_ file: DuplicateFile) -> SHA256Digest? {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        var total: Int64 = 0
        do {
            while let chunk = try handle.read(upToCount: chunkLength), !chunk.isEmpty {
                if Task.isCancelled { return nil }
                hash.update(data: chunk)
                total += Int64(chunk.count)
            }
        } catch {
            return nil
        }
        return total == file.size ? hash.finalize() : nil
    }

    /// Keeps the files whose bytes equal the first one's; anything that changed since hashing drops out.
    private static func confirmedGroup(_ bucket: [DuplicateFile]) -> [DuplicateFile] {
        guard let reference = bucket.first else { return [] }
        let same = [reference] + bucket.dropFirst().filter { sameBytes(reference.url, $0.url) }
        guard same.count > 1 else { return [] }
        return same.map { file in
            var file = file
            file.cloneID = ScanMetadataLoader.defaultCloneProbe(for: file.url).identity
            return file
        }
    }

    static func sameBytes(_ first: URL, _ second: URL) -> Bool {
        guard let a = try? FileHandle(forReadingFrom: first),
              let b = try? FileHandle(forReadingFrom: second) else { return false }
        defer {
            try? a.close()
            try? b.close()
        }
        do {
            while !Task.isCancelled {
                let left = try a.read(upToCount: chunkLength) ?? Data()
                let right = try b.read(upToCount: chunkLength) ?? Data()
                guard left == right else { return false }
                if left.isEmpty { return true }
            }
        } catch {}
        return false
    }

    private static func forEachConcurrently<Item: Sendable, Output: Sendable>(
        _ items: [Item],
        transform: @escaping @Sendable (Item) -> Output,
        each: (Output) -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Output.self) { group in
            var pending = items.makeIterator()
            for _ in 0..<parallelReads {
                guard let item = pending.next() else { break }
                group.addTask { transform(item) }
            }
            while let output = try await group.next() {
                try Task.checkCancellation()
                each(output)
                if let item = pending.next() {
                    group.addTask { transform(item) }
                }
            }
        }
    }
}

private nonisolated final class ErrorCounter: @unchecked Sendable {
    var count = 0
}
