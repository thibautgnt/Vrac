import Foundation

nonisolated enum CompressScanner {
    static var defaultRoots: [URL] {
        let fileManager = FileManager.default
        return [.moviesDirectory, .desktopDirectory, .downloadsDirectory, .documentDirectory]
            .compactMap { fileManager.urls(for: $0, in: .userDomainMask).first }
    }

    /// Files worth probing, largest first. Never descends into packages (Photos library, bundles).
    @concurrent
    static func candidateFiles(in roots: [URL]) async -> [URL] {
        enumerateCandidates(in: roots)
    }

    private static func enumerateCandidates(in roots: [URL]) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var found: [(url: URL, bytes: Int64)] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in enumerator {
                if Task.isCancelled { return [] }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let bytes = Int64(values.fileSize ?? 0)
                if CompressRules.isScanCandidate(url: url, bytes: bytes) {
                    found.append((url, bytes))
                }
            }
        }
        return found.sorted { $0.bytes > $1.bytes }.map(\.url)
    }

    static func info(for url: URL) async -> CompressMediaInfo? {
        switch CompressMediaKind(url: url) {
        case .video: await CompressVideoTranscoder.info(for: url)
        case .image: CompressImageTranscoder.info(for: url)
        case nil: nil
        }
    }
}
