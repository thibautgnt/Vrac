import AppKit
import Combine
import SwiftUI

nonisolated struct AppDataItem: Identifiable, Hashable, Sendable {
    let entry: LibraryEntry
    var bytes: Int64?

    var id: URL { entry.url }
}

nonisolated struct AppRow: Identifiable, Sendable {
    let app: InstalledApp
    var data: [AppDataItem]
    var bundleBytes: Int64?
    var lastUse: AppLastUse?

    var id: URL { app.url }
    var name: String { app.name }
    var dataBytes: Int64? { bundleBytes == nil || data.contains { $0.bytes == nil } ? nil : data.reduce(0) { $0 + ($1.bytes ?? 0) } }
    var totalBytes: Int64? { bundleBytes.flatMap { bundle in dataBytes.map { bundle + $0 } } }

    var versionSort: String { app.version ?? "" }
    var bundleSort: Int64 { bundleBytes ?? -1 }
    var dataSort: Int64 { dataBytes ?? -1 }
    var totalSort: Int64 { totalBytes ?? -1 }
    var sourceSort: String { source }
    var lastUseSort: Double {
        switch lastUse {
        case .date(let date): date.timeIntervalSince1970
        case .never: -1
        default: -2
        }
    }

    var source: String {
        if app.isSystemProtected { return "macOS" }
        return app.isAppStore ? "App Store" : String(localized: "Other", table: "Applications")
    }
}

struct LeftoverRow: Identifiable {
    let group: LeftoverGroup
    var sizes: [URL: Int64] = [:]

    var id: String { group.id }
    var bytes: Int64 { sizes.values.reduce(0, +) }
}

struct AppUsage: Equatable {
    let pid: pid_t
    var cpuPercent: Double?
    var memoryBytes: UInt64
}

struct ApplicationsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var reveal: URL?
}

@MainActor
final class ApplicationsRoomModel: ObservableObject {
    static let shared = ApplicationsRoomModel()

    enum Tab: Hashable {
        case apps
        case leftovers
        case startup
    }

    @Published var tab = Tab.apps
    @Published private(set) var rows: [AppRow] = []
    @Published var selection: AppRow.ID?
    @Published var search = ""
    @Published var sortOrder = [KeyPathComparator(\AppRow.totalSort, order: .reverse)]
    @Published var excludedData: Set<URL> = []
    @Published private(set) var usage: AppUsage?

    @Published private(set) var leftovers: [LeftoverRow] = []
    @Published var leftoverSelection: Set<String> = []

    @Published private(set) var launchItems: [LaunchItem] = []
    @Published private(set) var launchOwners: [URL: InstalledApp] = [:]
    @Published private(set) var togglingItems: Set<URL> = []

    @Published private(set) var isLoading = false
    @Published private(set) var isMeasuring = false
    @Published private(set) var isWorking = false
    @Published var alert: ApplicationsAlert?

    private var loadTask: Task<Void, Never>?
    private let home = FileManager.default.homeDirectoryForCurrentUser

    var visibleRows: [AppRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? rows : rows.filter {
            $0.name.localizedCaseInsensitiveContains(query) || ($0.app.bundleID?.localizedCaseInsensitiveContains(query) ?? false)
        }
        return filtered.sorted(using: sortOrder)
    }

    var selectedRow: AppRow? { rows.first { $0.id == selection } }

    func sharesBundleID(_ row: AppRow) -> Bool {
        guard let id = row.app.bundleID?.lowercased() else { return false }
        return rows.contains { $0.id != row.id && $0.app.bundleID?.lowercased() == id }
    }

    func loadIfNeeded() {
        if rows.isEmpty, loadTask == nil { refresh() }
    }

    func refresh() {
        loadTask?.cancel()
        isLoading = true
        let home = home
        loadTask = Task {
            let inventory = await Task.detached(priority: .userInitiated) { ApplicationsInventory.load(home: home) }.value
            guard !Task.isCancelled else { return }
            apply(inventory)
            isLoading = false
            isMeasuring = true
            await measure(inventory)
            if !Task.isCancelled { isMeasuring = false }
        }
    }

    private func apply(_ inventory: ApplicationsInventory) {
        rows = inventory.apps.map { app in
            AppRow(app: app, data: (inventory.associations[app.url] ?? []).map { AppDataItem(entry: $0) })
        }
        if let selection, !rows.contains(where: { $0.id == selection }) { self.selection = nil }
        // Data of a bundle id used by two installed copies (Xcode and its beta) belongs to both.
        excludedData.formUnion(rows.filter(sharesBundleID).flatMap { $0.data.map(\.id) })
        leftovers = inventory.leftovers.map { LeftoverRow(group: $0) }
        leftoverSelection.formIntersection(leftovers.map(\.id))
        setLaunchItems(inventory.launchItems)
    }

    private func setLaunchItems(_ items: [LaunchItem]) {
        launchItems = items
        let apps = rows.map(\.app)
        launchOwners = items.reduce(into: [:]) { owners, item in
            owners[item.id] = LaunchItems.owner(of: item, among: apps)
        }
    }

    private func measure(_ inventory: ApplicationsInventory) async {
        for group in inventory.leftovers {
            guard !Task.isCancelled else { return }
            let sizes = await Task.detached(priority: .utility) {
                group.entries.reduce(into: [URL: Int64]()) { $0[$1.url] = RoomTrash.allocatedSize(of: $1.url) }
            }.value
            if let index = leftovers.firstIndex(where: { $0.id == group.id }) { leftovers[index].sizes = sizes }
        }
        let apps = inventory.apps
        let associations = inventory.associations
        await withTaskGroup(of: (URL, Int64, [URL: Int64], AppLastUse).self) { group in
            var pending = apps.makeIterator()
            func next() {
                guard let app = pending.next() else { return }
                let entries = associations[app.url] ?? []
                group.addTask {
                    let sizes = entries.reduce(into: [URL: Int64]()) { $0[$1.url] = RoomTrash.allocatedSize(of: $1.url) }
                    return (app.url, RoomTrash.allocatedSize(of: app.url.resolvingSymlinksInPath()), sizes, InstalledApps.lastUse(of: app.url))
                }
            }
            for _ in 0..<4 { next() }
            for await (url, bundle, sizes, lastUse) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let index = rows.firstIndex(where: { $0.id == url }) {
                    rows[index].bundleBytes = bundle
                    rows[index].lastUse = lastUse
                    for item in rows[index].data.indices {
                        rows[index].data[item].bytes = sizes[rows[index].data[item].id] ?? 0
                    }
                }
                next()
            }
        }
    }

    func runningApplication(for app: InstalledApp) -> NSRunningApplication? {
        guard let bundleID = app.bundleID else { return nil }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let path = app.url.resolvingSymlinksInPath().path
        return running.first { $0.bundleURL?.resolvingSymlinksInPath().path == path } ?? running.first
    }

    /// Samples CPU and memory of the app every 2 seconds while the caller's task lives.
    func monitor(_ app: InstalledApp) async {
        var previous: AppProcessSample?
        usage = nil
        while !Task.isCancelled {
            if let running = runningApplication(for: app), let sample = ProcessUsage.sample(pid: running.processIdentifier) {
                let cpu = previous.map { ProcessUsage.cpuPercent(from: $0, to: sample) }
                usage = AppUsage(pid: running.processIdentifier, cpuPercent: cpu, memoryBytes: sample.memoryBytes)
                previous = sample
            } else {
                usage = nil
                previous = nil
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func quit(_ app: InstalledApp) {
        runningApplication(for: app)?.terminate()
    }

    func selectedData(of row: AppRow) -> [AppDataItem] {
        row.data.filter { !excludedData.contains($0.id) }
    }

    /// Moves the bundle (when `uninstall`) then the checked data of `row` to the Trash.
    /// The bundle goes first so that a refused uninstall never leaves the app without its data.
    func remove(_ row: AppRow, uninstall: Bool) {
        guard !isWorking, !row.app.isSystemProtected else { return }
        if runningApplication(for: row.app) != nil {
            alert = ApplicationsAlert(
                title: String(localized: "\(row.name) is open", table: "Applications"),
                message: String(localized: "Quit the app before removing it.", table: "Applications")
            )
            return
        }
        let bundle = RoomTrashItem(url: row.app.url, bytes: row.bundleBytes ?? 0)
        let data = selectedData(of: row).map { RoomTrashItem(url: $0.entry.url, bytes: $0.bytes ?? 0) }
        isWorking = true
        Task {
            let (bundleResult, dataResult) = await Task.detached(priority: .userInitiated) { () -> (RoomTrashResult?, RoomTrashResult) in
                guard uninstall else { return (nil, RoomTrash.moveToTrash(data)) }
                let bundleResult = RoomTrash.moveToTrash([bundle])
                guard bundleResult.failures.isEmpty else { return (bundleResult, RoomTrashResult()) }
                return (bundleResult, RoomTrash.moveToTrash(data))
            }.value
            isWorking = false

            if let failure = bundleResult?.failures.first {
                alert = ApplicationsAlert(
                    title: String(localized: "Could not uninstall \(row.name)", table: "Applications"),
                    message: failure.reason + "\n\n" + String(localized: "If macOS refuses, allow Vrac in System Settings > Privacy & Security > App Management, or drag the app to the Trash in the Finder.", table: "Applications"),
                    reveal: row.app.url
                )
                return
            }
            let trashed = Set(dataResult.trashedURLs)
            if bundleResult != nil {
                rows.removeAll { $0.id == row.id }
                selection = nil
            } else if let index = rows.firstIndex(where: { $0.id == row.id }) {
                rows[index].data.removeAll { trashed.contains($0.id) }
            }
            excludedData.subtract(trashed)
            if !dataResult.failures.isEmpty {
                alert = failureAlert(dataResult.failures)
            }
        }
    }

    var selectedLeftoverItems: [RoomTrashItem] {
        leftovers.filter { leftoverSelection.contains($0.id) }.flatMap { row in
            row.group.entries.map { RoomTrashItem(url: $0.url, bytes: row.sizes[$0.url] ?? 0) }
        }
    }

    func trashSelectedLeftovers() {
        let items = selectedLeftoverItems
        guard !items.isEmpty, !isWorking else { return }
        isWorking = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { RoomTrash.moveToTrash(items) }.value
            isWorking = false
            let trashed = Set(result.trashedURLs)
            leftovers = leftovers.compactMap { row in
                let remaining = row.group.entries.filter { !trashed.contains($0.url) }
                guard !remaining.isEmpty else { return nil }
                return LeftoverRow(group: LeftoverGroup(identifier: row.group.identifier, entries: remaining), sizes: row.sizes)
            }
            leftoverSelection.formIntersection(leftovers.map(\.id))
            if !result.failures.isEmpty { alert = failureAlert(result.failures) }
        }
    }

    func setEnabled(_ enabled: Bool, item: LaunchItem) {
        guard item.scope == .userAgent, !togglingItems.contains(item.id) else { return }
        togglingItems.insert(item.id)
        let home = home
        Task {
            let (error, items) = await Task.detached(priority: .userInitiated) {
                (LaunchItems.setEnabled(enabled, item: item), LaunchItems.load(home: home))
            }.value
            togglingItems.remove(item.id)
            setLaunchItems(items)
            if let error {
                alert = ApplicationsAlert(title: String(localized: "Could not change \(item.label)", table: "Applications"), message: error)
            }
        }
    }

    private func failureAlert(_ failures: [RoomTrashFailure]) -> ApplicationsAlert {
        ApplicationsAlert(
            title: String(localized: "Some items could not be moved to the Trash", table: "Applications"),
            message: failures.prefix(5).map { "\($0.url.lastPathComponent): \($0.reason)" }.joined(separator: "\n"),
            reveal: failures.first?.url
        )
    }
}
