import AppKit
import Combine
import SwiftUI

@MainActor
final class CleanupRoomModel: ObservableObject {
    static let shared = CleanupRoomModel()

    enum Phase: Equatable {
        case idle, scanning, done
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var items: [CleanupItem] = []
    @Published private(set) var unreadableLocations = 0
    @Published private(set) var isTrashing = false
    @Published var selection: Set<URL> = []
    @Published var lastTrash: RoomTrashResult?

    private var scanTask: Task<Void, Never>?
    private var presented: Set<URL> = []
    private var trashed: Set<URL> = []

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var selectedItems: [CleanupItem] { items.filter { selection.contains($0.url) } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    func items(in category: CleanupCategory) -> [CleanupItem] {
        items.filter { $0.category == category }
    }

    func scanIfNeeded() {
        if phase == .idle { rescan() }
    }

    func rescan() {
        scanTask?.cancel()
        phase = .scanning
        progress = 0
        items = []
        selection = []
        let environment = Self.environment()
        presented = []
        trashed = []
        scanTask = Task { [weak self] in
            let result = await CleanupScanner.scan(environment) { partial, progress in
                Task { @MainActor in
                    guard let self, self.phase == .scanning else { return }
                    self.progress = progress
                    self.present(partial)
                }
            }
            guard let self, !Task.isCancelled else { return }
            present(result)
            phase = .done
        }
    }

    /// Items appear as rules finish; only newly seen items get their default selection,
    /// so choices made during the scan stick.
    private func present(_ result: CleanupScanResult) {
        let current = result.items.filter { !trashed.contains($0.url) }
        let fresh = current.filter { !presented.contains($0.url) }
        selection.formUnion(fresh.filter(\.isRecommended).map(\.url))
        presented.formUnion(fresh.map(\.url))
        items = current
        selection.formIntersection(Set(items.map(\.url)))
        unreadableLocations = result.unreadableLocations
    }

    func binding(for item: CleanupItem) -> Binding<Bool> {
        Binding(
            get: { self.selection.contains(item.url) },
            set: { isOn in
                if isOn { self.selection.insert(item.url) } else { self.selection.remove(item.url) }
            }
        )
    }

    func moveSelectionToTrash() {
        let targets = selectedItems.map { RoomTrashItem(url: $0.url, bytes: $0.bytes) }
        guard !targets.isEmpty else { return }
        isTrashing = true
        Task {
            let result = await Self.trash(targets)
            trashed.formUnion(result.trashedURLs)
            items.removeAll { trashed.contains($0.url) }
            selection.subtract(trashed)
            lastTrash = result
            isTrashing = false
        }
    }

    @concurrent
    private nonisolated static func trash(_ items: [RoomTrashItem]) async -> RoomTrashResult {
        RoomTrash.moveToTrash(items)
    }

    private static func environment() -> CleanupEnvironment {
        var environment = CleanupEnvironment(home: URL(fileURLWithPath: NSHomeDirectory()))
        environment.runningApps = Set(NSWorkspace.shared.runningApplications.flatMap {
            [$0.bundleIdentifier, $0.localizedName].compactMap { $0?.lowercased() }
        })
        let appFolders = ["/Applications", NSHomeDirectory() + "/Applications"]
        environment.installedApps = Set(appFolders.flatMap {
            ((try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [])
                .filter { $0.hasSuffix(".app") }
                .map { String($0.dropLast(4)).lowercased() }
        })
        environment.appName = { bundleID in
            guard bundleID.contains("."),
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return url.deletingPathExtension().lastPathComponent
        }
        return environment
    }
}
