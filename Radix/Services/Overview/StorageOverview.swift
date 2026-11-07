import Foundation

nonisolated enum OverviewCategory: String, CaseIterable, Sendable {
    case applications, documents, downloads, media, iCloud, developer, mail, otherUser, system
}

nonisolated struct OverviewJob: Hashable, Sendable {
    let category: OverviewCategory
    let url: URL
    var excluded: Set<String> = []

    func contains(_ path: String) -> Bool {
        (path == url.path || path.hasPrefix(url.path + "/"))
            && !excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

nonisolated struct VolumeSnapshot: Sendable, Equatable {
    var name: String
    var total: Int64
    var available: Int64
    var availableForImportantUsage: Int64

    var used: Int64 { max(0, total - available) }
    var purgeable: Int64 { max(0, availableForImportantUsage - available) }

    static func startup() -> VolumeSnapshot? {
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        let available = Int64(values.volumeAvailableCapacity ?? 0)
        return VolumeSnapshot(
            name: values.volumeLocalizedName ?? "Macintosh HD",
            total: Int64(total),
            available: available,
            availableForImportantUsage: max(available, values.volumeAvailableCapacityForImportantUsage ?? 0)
        )
    }
}

/// Splits the startup disk into categories so every byte is measured once:
/// nested roots are excluded from their parent, and the rest of the home goes to `otherUser`.
nonisolated enum OverviewAccounting {
    static func defaultRoots(home: URL) -> [(OverviewCategory, [URL])] {
        let inHome = { (paths: [String]) in paths.map { home.appendingPathComponent($0) } }
        return [
            (.applications, [URL(fileURLWithPath: "/Applications")] + inHome(["Applications"])),
            (.documents, inHome(["Documents", "Desktop"])),
            (.downloads, inHome(["Downloads"])),
            (.media, inHome(["Pictures", "Movies", "Music"])),
            (.iCloud, inHome(["Library/Mobile Documents"])),
            (.developer, inHome(["Library/Developer"] + CleanupScanner.devRoots)),
            (.mail, inHome(["Library/Mail", "Library/Containers/com.apple.mail", "Library/Messages"])),
        ]
    }

    /// `isEligible` says whether a resolved root exists on the startup volume.
    /// The home and its Library are split into their children so the work runs in parallel.
    static func jobs(
        home: URL,
        roots: [(OverviewCategory, [URL])],
        isEligible: (URL) -> Bool,
        children: (URL) -> [URL]
    ) -> [OverviewJob] {
        let home = home.resolvingSymlinksInPath()
        var categoryRoots: [(OverviewCategory, URL)] = []
        for (category, urls) in roots {
            for url in urls.map({ $0.resolvingSymlinksInPath() }) where isEligible(url) {
                if categoryRoots.contains(where: { $0.1.path == url.path }) { continue }
                categoryRoots.append((category, url))
            }
        }
        // A root inside another root of the same category is already counted there.
        let kept = categoryRoots.filter { root in
            !categoryRoots.contains { $0.0 == root.0 && root.1.path.hasPrefix($0.1.path + "/") }
        }
        let rootPaths = kept.map(\.1.path)

        func nested(in url: URL) -> Set<String> {
            Set(rootPaths.filter { $0.hasPrefix(url.path + "/") })
        }

        var jobs = kept.map { OverviewJob(category: $0.0, url: $0.1, excluded: nested(in: $0.1)) }

        let split = [home.path, home.appendingPathComponent("Library").path]
        func addOther(_ directory: URL) {
            for child in children(directory) {
                let child = child.standardizedFileURL
                if rootPaths.contains(child.path) { continue }
                if split.contains(child.path) {
                    addOther(child)
                } else if isEligible(child) {
                    jobs.append(OverviewJob(category: .otherUser, url: child, excluded: nested(in: child)))
                }
            }
        }
        if !rootPaths.contains(home.path) { addOther(home) }
        return jobs
    }

    static func category(of url: URL, in jobs: [OverviewJob]) -> OverviewCategory? {
        let path = url.standardizedFileURL.path
        return jobs.first { $0.contains(path) }?.category
    }

    /// Kept bytes per category (reclaimable carved out), the system remainder and the reclaimable total.
    static func breakdown(
        measured: [OverviewCategory: Int64],
        used: Int64,
        reclaimable: [OverviewCategory: Int64]
    ) -> (kept: [OverviewCategory: Int64], reclaimable: Int64) {
        var sizes = measured
        sizes[.system] = nil
        sizes[.system] = max(0, used - sizes.values.reduce(0, +))
        var kept: [OverviewCategory: Int64] = [:]
        var carved: Int64 = 0
        for (category, size) in sizes {
            let part = min(max(0, reclaimable[category] ?? 0), size)
            kept[category] = size - part
            carved += part
        }
        return (kept, carved)
    }
}
