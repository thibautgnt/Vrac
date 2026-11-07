import Foundation

nonisolated enum DuplicateKeepRule: String, CaseIterable, Sendable {
    case oldest, newest, shortestPath, outsideDownloads

    func keeper(of group: DuplicateGroup, downloads: URL) -> DuplicateFile? {
        let byAge: (DuplicateFile, DuplicateFile) -> Bool = { ($0.created ?? $0.modified, $0.url.path) < ($1.created ?? $1.modified, $1.url.path) }
        switch self {
        case .oldest:
            return group.files.min(by: byAge)
        case .newest:
            return group.files.max(by: byAge)
        case .shortestPath:
            return group.files.min { ($0.url.path.count, $0.url.path) < ($1.url.path.count, $1.url.path) }
        case .outsideDownloads:
            let prefix = downloads.standardizedFileURL.path + "/"
            let outside = group.files.filter { !$0.url.standardizedFileURL.path.hasPrefix(prefix) }
            return (outside.isEmpty ? group.files : outside).min(by: byAge)
        }
    }
}

/// Files picked for the Trash. Invariant: every group keeps at least one unselected copy.
nonisolated struct DuplicateSelection: Equatable, Sendable {
    private(set) var selected: Set<URL> = []

    func contains(_ file: DuplicateFile) -> Bool {
        selected.contains(file.url)
    }

    func canSelect(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool {
        contains(file) || group.files.contains { $0.url != file.url && !contains($0) }
    }

    mutating func toggle(_ file: DuplicateFile, in group: DuplicateGroup) {
        if contains(file) {
            selected.remove(file.url)
        } else if canSelect(file, in: group) {
            selected.insert(file.url)
        }
    }

    /// Selects every copy that does not share storage with the rule's keeper.
    mutating func apply(_ rule: DuplicateKeepRule, to groups: [DuplicateGroup], downloads: URL) {
        selected = []
        for group in groups {
            guard let keeper = rule.keeper(of: group, downloads: downloads) else { continue }
            for file in group.files where file.storageKey != keeper.storageKey {
                selected.insert(file.url)
            }
        }
    }

    mutating func prune(to groups: [DuplicateGroup]) {
        let urls = Set(groups.flatMap { $0.files.map(\.url) })
        selected.formIntersection(urls)
    }

    func selectedCount(in groups: [DuplicateGroup]) -> Int {
        groups.reduce(0) { $0 + $1.files.count(where: contains) }
    }

    /// Space actually freed: a set of clones only frees its blocks once all of them go.
    func reclaimableBytes(in groups: [DuplicateGroup]) -> Int64 {
        trashItems(in: groups).reduce(0) { $0 + $1.bytes }
    }

    func trashItems(in groups: [DuplicateGroup]) -> [RoomTrashItem] {
        groups.flatMap { group in
            Dictionary(grouping: group.files, by: \.storageKey).values.flatMap { unit -> [RoomTrashItem] in
                let picked = unit.filter { contains($0) }
                let freesStorage = picked.count == unit.count
                return picked.enumerated().map { index, file in
                    RoomTrashItem(url: file.url, bytes: freesStorage && index == 0 ? group.size : 0)
                }
            }
        }
    }

    /// Items safe to trash now, and selected files skipped because they, or every kept copy, changed since the scan.
    func trashPlan(in groups: [DuplicateGroup]) -> (items: [RoomTrashItem], skipped: [URL]) {
        var items: [RoomTrashItem] = []
        var skipped: [URL] = []
        for group in groups {
            let picked = trashItems(in: [group])
            guard !picked.isEmpty else { continue }
            let keptCopyIsIntact = group.files.contains { !contains($0) && $0.isUnchanged }
            let filesByURL = Dictionary(uniqueKeysWithValues: group.files.map { ($0.url, $0) })
            for item in picked {
                if keptCopyIsIntact, filesByURL[item.url]?.isUnchanged == true {
                    items.append(item)
                } else {
                    skipped.append(item.url)
                }
            }
        }
        return (items, skipped)
    }
}
