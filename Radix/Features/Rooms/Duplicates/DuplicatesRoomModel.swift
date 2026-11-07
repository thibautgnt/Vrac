import AppKit
import Combine
import SwiftUI

@MainActor
final class DuplicatesRoomModel: ObservableObject {
    static let shared = DuplicatesRoomModel()
    static let minimumSizes: [Int64] = [100_000, 1_000_000, 10_000_000, 100_000_000]

    enum State { case idle, scanning, results }

    struct TrashReport {
        let trashedCount: Int
        let freedBytes: Int64
        let failures: [RoomTrashFailure]
        let skipped: [URL]
    }

    @Published var roots: [URL] = [FileManager.default.homeDirectoryForCurrentUser]
    @Published var minimumSize: Int64 = 1_000_000
    @Published var includesLibrary = false
    @Published var searchText = ""
    @Published var kind: DuplicateKind?
    @Published var rule: DuplicateKeepRule = .oldest {
        didSet { selection.apply(rule, to: groups, downloads: downloads) }
    }
    @Published private(set) var state: State = .idle
    @Published private(set) var progress = DuplicateScanProgress()
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var filesSeen = 0
    @Published private(set) var unreadableCount = 0
    @Published private(set) var selection = DuplicateSelection()
    @Published private(set) var isTrashing = false
    @Published private(set) var trashReport: TrashReport?

    private var scanTask: Task<Void, Never>?
    private let downloads = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")

    var visibleGroups: [DuplicateGroup] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return groups.filter { group in
            (kind == nil || group.kind == kind)
                && (query.isEmpty || group.files.contains { $0.url.lastPathComponent.localizedCaseInsensitiveContains(query) })
        }
    }

    var reclaimableBytes: Int64 { groups.reduce(0) { $0 + $1.reclaimableBytes } }
    var fileCount: Int { groups.reduce(0) { $0 + $1.files.count } }

    func isSelected(_ file: DuplicateFile) -> Bool { selection.contains(file) }
    func canSelect(_ file: DuplicateFile, in group: DuplicateGroup) -> Bool { selection.canSelect(file, in: group) }
    func toggle(_ file: DuplicateFile, in group: DuplicateGroup) { selection.toggle(file, in: group) }

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add", table: "Duplicates")
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func add(_ urls: [URL]) {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for folder in folders where !roots.contains(folder.standardizedFileURL) {
            roots.append(folder.standardizedFileURL)
        }
    }

    func remove(_ url: URL) {
        guard roots.count > 1 else { return }
        roots.removeAll { $0 == url }
    }

    func start() {
        scanTask?.cancel()
        trashReport = nil
        progress = DuplicateScanProgress()
        state = .scanning
        let options = DuplicateScanOptions(roots: roots, minimumSize: minimumSize, includesLibrary: includesLibrary)
        scanTask = Task {
            let result = try? await DuplicateFinder.scan(options) { [weak self] progress in
                Task { @MainActor in
                    if self?.state == .scanning { self?.progress = progress }
                }
            }
            guard !Task.isCancelled, let result else { return }
            groups = result.groups
            filesSeen = result.filesSeen
            unreadableCount = result.unreadableCount
            selection.apply(rule, to: groups, downloads: downloads)
            state = .results
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        state = .idle
    }

    func startOver() {
        groups = []
        selection = DuplicateSelection()
        trashReport = nil
        state = .idle
    }

    func moveSelectionToTrash() {
        let groups = groups
        let selection = selection
        isTrashing = true
        Task {
            let (result, skipped) = await Self.trash(selection, in: groups)
            let trashed = Set(result.trashedURLs)
            self.groups = self.groups.compactMap { group in
                var group = group
                group.files.removeAll { trashed.contains($0.url) }
                return group.files.count > 1 ? group : nil
            }
            self.selection.prune(to: self.groups)
            trashReport = TrashReport(trashedCount: trashed.count, freedBytes: result.freedBytes, failures: result.failures, skipped: skipped)
            isTrashing = false
        }
    }

    @concurrent
    private nonisolated static func trash(_ selection: DuplicateSelection, in groups: [DuplicateGroup]) async -> (RoomTrashResult, [URL]) {
        let plan = selection.trashPlan(in: groups)
        return (RoomTrash.moveToTrash(plan.items), plan.skipped)
    }

    #if DEBUG
    private var didStartDebugScan = false

    /// `-VracDuplicatesScan <folder>` scans a fixture folder at launch, for screenshots.
    func startDebugScanIfRequested() {
        guard !didStartDebugScan, let path = UserDefaults.standard.string(forKey: "VracDuplicatesScan") else { return }
        didStartDebugScan = true
        roots = [URL(fileURLWithPath: path)]
        minimumSize = Self.minimumSizes[0]
        start()
    }
    #endif
}
