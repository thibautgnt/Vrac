import Combine
import Foundation

@MainActor
final class CompressRoomModel: ObservableObject {
    static let shared = CompressRoomModel()

    enum Status: Equatable {
        case ready
        case queued
        case working(Double?)
        case done(CompressResult)
        case alreadyOptimized
        case failed(String)
    }

    struct Item: Identifiable, Equatable {
        let sourceURL: URL
        /// Where the file lives now; differs from `sourceURL` once the output replaced the original.
        var url: URL
        let info: CompressMediaInfo
        var isSelected: Bool
        var status: Status = .ready

        var id: URL { sourceURL }

        init(url: URL, info: CompressMediaInfo, isSelected: Bool) {
            sourceURL = url
            self.url = url
            self.info = info
            self.isSelected = isSelected
        }
    }

    @Published private(set) var items: [Item] = []
    @Published var settings = CompressSettings() {
        didSet { if settings != oldValue { refreshEstimates() } }
    }
    @Published var replaceOriginals = false
    @Published private(set) var isScanning = false
    @Published private(set) var isRunning = false
    @Published private(set) var lastScanFoundNothing = false
    @Published private var estimates: [String: Int64] = [:]

    private var runIDs: [URL] = []
    private var reservedOutputs: Set<URL> = []
    private var scanTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var estimateTask: Task<Void, Never>?
    private static let maxConcurrentImages = 3

    private init() {
        #if DEBUG
        if let folder = UserDefaults.standard.string(forKey: "VracCompressFixture") {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            add(urls.sorted { $0.lastPathComponent < $1.lastPathComponent })
            replaceOriginals = UserDefaults.standard.bool(forKey: "VracCompressReplace")
            if UserDefaults.standard.bool(forKey: "VracCompressAutorun") {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    compressSelected()
                }
            }
        }
        #endif
    }

    func estimate(for item: Item) -> Int64? {
        estimates[estimateKey(item)].flatMap { $0 > 0 ? $0 : nil }
    }

    var potentialSavings: Int64 {
        items.reduce(0) { total, item in
            guard item.status == .ready, let estimate = estimate(for: item),
                  CompressRules.isWorthKeeping(originalBytes: item.info.bytes, outputBytes: estimate) else { return total }
            return total + item.info.bytes - estimate
        }
    }

    var results: [CompressResult] {
        items.compactMap { if case .done(let result) = $0.status { result } else { nil } }
    }

    var selectedCount: Int {
        items.filter { $0.isSelected && $0.canStart }.count
    }

    var overallProgress: Double {
        guard !runIDs.isEmpty else { return 0 }
        let total = runIDs.reduce(0.0) { sum, id in
            switch items.first(where: { $0.id == id })?.status {
            case .queued, .ready, nil: sum
            case .working(let progress): sum + (progress ?? 0.5)
            default: sum + 1
            }
        }
        return total / Double(runIDs.count)
    }

    var allSelected: Bool {
        let startable = items.filter(\.canStart)
        return !startable.isEmpty && startable.allSatisfy(\.isSelected)
    }

    func setAllSelected(_ selected: Bool) {
        for index in items.indices where items[index].canStart {
            items[index].isSelected = selected
        }
    }

    func setSelected(_ id: URL, _ selected: Bool) {
        update(id) { $0.isSelected = selected }
    }

    func remove(_ id: URL) {
        guard items.first(where: { $0.id == id })?.isBusy == false else { return }
        items.removeAll { $0.id == id }
    }

    func clearFinished() {
        items.removeAll { if case .done = $0.status { true } else { $0.status == .alreadyOptimized } }
    }

    func findCandidates() {
        guard !isScanning else { return }
        isScanning = true
        lastScanFoundNothing = false
        scanTask = Task {
            let before = items.count
            for url in await CompressScanner.candidateFiles(in: CompressScanner.defaultRoots) {
                if Task.isCancelled { break }
                guard !contains(url), let info = await CompressScanner.info(for: url),
                      CompressRules.isWorthCompressing(info) else { continue }
                items.append(Item(url: url, info: info, isSelected: false))
            }
            isScanning = false
            lastScanFoundNothing = items.count == before
            refreshEstimates()
        }
    }

    func add(_ urls: [URL]) {
        Task {
            for url in urls where !contains(url) {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let info = await CompressScanner.info(for: url) else { continue }
                items.append(Item(url: url, info: info, isSelected: true))
            }
            refreshEstimates()
        }
    }

    func compressSelected() {
        guard !isRunning else { return }
        let ids = items.filter { $0.isSelected && $0.canStart }.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { update(id) { $0.status = .queued } }
        runIDs = ids
        isRunning = true
        let settings = settings
        let replace = replaceOriginals
        let videos = ids.filter { id in items.first { $0.id == id }?.info.kind == .video }
        let images = ids.filter { !videos.contains($0) }
        runTask = Task {
            async let videoLane: Void = runSerially(videos, settings: settings, replace: replace)
            async let imageLane: Void = runConcurrently(images, settings: settings, replace: replace)
            _ = await (videoLane, imageLane)
            isRunning = false
            refreshEstimates()
        }
    }

    func cancel() {
        runTask?.cancel()
        for id in runIDs {
            update(id) { if $0.status == .queued { $0.status = .ready } }
        }
    }

    private func runSerially(_ ids: [URL], settings: CompressSettings, replace: Bool) async {
        for id in ids {
            if Task.isCancelled { return }
            await process(id, settings: settings, replace: replace)
        }
    }

    private func runConcurrently(_ ids: [URL], settings: CompressSettings, replace: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            var pending = ids[...]
            for _ in 0..<Self.maxConcurrentImages {
                guard let id = pending.popFirst() else { break }
                group.addTask { await self.process(id, settings: settings, replace: replace) }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, let id = pending.popFirst() else { continue }
                group.addTask { await self.process(id, settings: settings, replace: replace) }
            }
        }
    }

    private func process(_ id: URL, settings: CompressSettings, replace: Bool) async {
        guard !Task.isCancelled, let item = items.first(where: { $0.id == id }) else { return }
        update(id) { $0.status = .working(item.info.kind == .video ? 0 : nil) }
        let original = item.url
        let info = item.info
        let pathExtension = info.kind == .video ? CompressVideoTranscoder.outputExtension(for: original) : "heic"
        let output = CompressRules.outputURL(for: original, pathExtension: pathExtension) { [reservedOutputs] in
            reservedOutputs.contains($0) || FileManager.default.fileExists(atPath: $0.path)
        }
        reservedOutputs.insert(output)
        defer { reservedOutputs.remove(output) }

        do {
            try await CompressPipeline.write(output, near: original) { partial in
                switch info.kind {
                case .video:
                    try await CompressVideoTranscoder.export(original, to: partial, preset: settings.videoPreset) { progress in
                        Task { @MainActor in
                            self.update(id) { if case .working = $0.status { $0.status = .working(progress) } }
                        }
                    }
                case .image:
                    try await CompressImageTranscoder.transcode(
                        original, to: partial, quality: settings.imageQuality, maxPixelSize: settings.imageMaxPixelSize)
                }
            }
        } catch {
            update(id) { $0.status = Task.isCancelled ? .ready : .failed(error.localizedDescription) }
            return
        }

        let outcome = await CompressPipeline.finish(
            original: original,
            output: output,
            replaceOriginal: replace,
            verify: { output in
                switch info.kind {
                case .video: await CompressVideoTranscoder.verify(output, original: info, preset: settings.videoPreset)
                case .image: await CompressImageTranscoder.verify(output, original: info, maxPixelSize: settings.imageMaxPixelSize)
                }
            },
            trash: { url in
                RoomTrash.moveToTrash([RoomTrashItem(url: url, bytes: info.bytes)]).failures.first?.reason
            }
        )
        update(id) {
            $0.isSelected = false
            switch outcome {
            case .compressed(let result):
                $0.status = .done(result)
                if result.replacedOriginal { $0.url = result.output }
            case .alreadyOptimized:
                $0.status = .alreadyOptimized
            case .verificationFailed:
                $0.status = .failed(String(localized: "The compressed file could not be verified, it was deleted.", table: "Compress"))
            }
        }
    }

    private func refreshEstimates() {
        estimateTask?.cancel()
        let settings = settings
        estimateTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            for item in items where item.status == .ready || item.status == .queued {
                if Task.isCancelled { return }
                let key = estimateKey(item, settings: settings)
                guard estimates[key] == nil else { continue }
                let bytes: Int64? = switch item.info.kind {
                case .video: await CompressVideoTranscoder.estimate(item.url, preset: settings.videoPreset)
                case .image: try? await Int64(CompressImageTranscoder.encode(
                    item.url, quality: settings.imageQuality, maxPixelSize: settings.imageMaxPixelSize).count)
                }
                if Task.isCancelled { return }
                estimates[key] = bytes ?? 0
            }
        }
    }

    private func estimateKey(_ item: Item, settings: CompressSettings? = nil) -> String {
        "\(item.sourceURL.path)|\((settings ?? self.settings).cacheKey(for: item.info.kind))"
    }

    private func contains(_ url: URL) -> Bool {
        items.contains { $0.sourceURL == url || $0.url == url }
    }

    private func update(_ id: URL, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
}

extension CompressRoomModel.Item {
    var canStart: Bool {
        switch status {
        case .ready, .failed: true
        default: false
        }
    }

    var isBusy: Bool {
        switch status {
        case .queued, .working: true
        default: false
        }
    }
}
