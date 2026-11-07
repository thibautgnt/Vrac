import Combine
import Foundation

@MainActor
final class OverviewRoomModel: ObservableObject {
    static let shared = OverviewRoomModel()

    @Published private(set) var volume: VolumeSnapshot?
    @Published private(set) var measured: [OverviewCategory: Int64] = [:]
    @Published private(set) var jobs: [OverviewJob] = []
    @Published private(set) var pendingJobs: [OverviewCategory: Int] = [:]
    @Published private(set) var unreadableFolders = 0
    @Published private(set) var isMeasuring = false
    @Published private(set) var lastUpdated: Date?

    private var task: Task<Void, Never>?

    var progress: Double {
        guard !jobs.isEmpty else { return 0 }
        return 1 - Double(pendingJobs.values.reduce(0, +)) / Double(jobs.count)
    }

    func loadIfNeeded() {
        if lastUpdated == nil, !isMeasuring { refresh() }
    }

    func refresh() {
        task?.cancel()
        volume = VolumeSnapshot.startup()
        measured = [:]
        jobs = []
        pendingJobs = [:]
        unreadableFolders = 0
        isMeasuring = true
        task = Task { [weak self] in
            let jobs = await Self.plannedJobs()
            guard let self, !Task.isCancelled else { return }
            self.jobs = jobs
            pendingJobs = Dictionary(jobs.map { ($0.category, 1) }, uniquingKeysWith: +)
            await withTaskGroup(of: (OverviewJob, DirectoryUsage).self) { group in
                var queue = jobs.makeIterator()
                for _ in 0..<12 {
                    guard let job = queue.next() else { break }
                    group.addTask { (job, await Self.measure(job)) }
                }
                while let (job, usage) = await group.next() {
                    guard !Task.isCancelled else { group.cancelAll(); continue }
                    measured[job.category, default: 0] += usage.bytes
                    unreadableFolders += usage.unreadableFolders
                    pendingJobs[job.category, default: 1] -= 1
                    if let next = queue.next() {
                        group.addTask { (next, await Self.measure(next)) }
                    }
                }
            }
            guard !Task.isCancelled else { return }
            isMeasuring = false
            lastUpdated = Date()
            volume = VolumeSnapshot.startup()
        }
    }

    @concurrent
    private nonisolated static func measure(_ job: OverviewJob) async -> DirectoryUsage {
        await BlockingIO.run { DirectorySizer.usage(of: job.url, excluding: job.excluded, isCancelled: $0) }
    }

    @concurrent
    private nonisolated static func plannedJobs() async -> [OverviewJob] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var homeInfo = stat()
        guard stat(home.path, &homeInfo) == 0 else { return [] }
        return OverviewAccounting.jobs(
            home: home,
            roots: OverviewAccounting.defaultRoots(home: home),
            isEligible: { url in
                var info = stat()
                return stat(url.path, &info) == 0 && info.st_dev == homeInfo.st_dev
            },
            children: { url in
                (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            }
        )
    }
}
