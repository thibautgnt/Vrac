import Foundation

nonisolated enum CleanupCategory: String, CaseIterable, Sendable {
    case appCaches, logs, developer, installers, oldDownloads, mailAttachments
}

nonisolated struct CleanupItem: Identifiable, Hashable, Sendable {
    let url: URL
    let category: CleanupCategory
    var title: String
    var bytes: Int64 = 0
    var lastUsed: Date?
    var isAppRunning = false
    var isRecommended: Bool

    var id: URL { url }
}

nonisolated struct CleanupRule: Sendable {
    enum Scope: Sendable {
        /// The path itself is one item.
        case folder
        /// Each visible child of the path is one item.
        case eachChild
        /// `node_modules`, `.build` and `target` folders of projects under the paths.
        case buildArtifacts
    }

    enum Selection: Sendable {
        case always
        case never
        case olderThan(days: Int)
    }

    let category: CleanupCategory
    /// Relative to the home folder.
    let paths: [String]
    var scope: Scope = .folder
    var selection: Selection = .always
    var minimumAgeDays: Int?
    var installersOnly = false
}

nonisolated struct CleanupEnvironment: Sendable {
    var home: URL
    var now = Date()
    /// Lowercased bundle identifiers and names of running apps.
    var runningApps: Set<String> = []
    /// Lowercased names of installed apps, without `.app`.
    var installedApps: Set<String> = []
    var appName: @Sendable (String) -> String? = { _ in nil }
    var isProtected: @Sendable (URL) -> Bool = { TrashSafetyPolicy.blockReason(for: $0) != nil }
}

nonisolated struct CleanupScanResult: Sendable {
    var items: [CleanupItem] = []
    var unreadableLocations = 0
}

nonisolated enum CleanupScanner {
    static let devRoots = [
        "Dev", "Developer", "Projects", "Code", "code", "src", "Sites", "workspace", "GitHub",
    ]

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip"]

    /// Order matters: a path listed by an earlier rule is never listed again by a later one.
    static let rules: [CleanupRule] = [
        CleanupRule(category: .developer, paths: ["Library/Developer/Xcode/DerivedData"], scope: .eachChild),
        CleanupRule(
            category: .developer,
            paths: ["iOS", "watchOS", "tvOS", "visionOS", "macOS"].map { "Library/Developer/Xcode/\($0) DeviceSupport" },
            scope: .eachChild
        ),
        CleanupRule(category: .developer, paths: ["Library/Developer/CoreSimulator/Caches"]),
        CleanupRule(category: .developer, paths: ["Library/Developer/Xcode/Archives"], scope: .eachChild, selection: .never),
        CleanupRule(category: .developer, paths: [
            "Library/Caches/Homebrew", "Library/Caches/pip", "Library/Caches/CocoaPods",
            "Library/Caches/org.swift.swiftpm", "Library/Caches/Yarn", "Library/Caches/go-build",
            "Library/Caches/pnpm", ".npm/_cacache", ".gradle/caches", ".cargo/registry/cache",
        ]),
        CleanupRule(category: .developer, paths: [".cache"], scope: .eachChild, selection: .never),
        CleanupRule(category: .developer, paths: devRoots, scope: .buildArtifacts, selection: .never, minimumAgeDays: 30),
        CleanupRule(category: .logs, paths: ["Library/Logs/DiagnosticReports"], scope: .eachChild),
        CleanupRule(category: .logs, paths: ["Library/Logs"], scope: .eachChild),
        CleanupRule(category: .mailAttachments, paths: ["Library/Containers/com.apple.mail/Data/Library/Mail Downloads"]),
        CleanupRule(
            category: .installers,
            paths: ["Downloads", "Desktop"],
            scope: .eachChild,
            selection: .olderThan(days: 7),
            installersOnly: true
        ),
        CleanupRule(category: .oldDownloads, paths: ["Downloads"], scope: .eachChild, selection: .never, minimumAgeDays: 90),
        CleanupRule(category: .appCaches, paths: ["Library/Caches"], scope: .eachChild),
    ]

    private enum ScanEvent: Sendable {
        case found(Int, CleanupScanResult)
        case sized(Int, CleanupItem, DirectoryUsage)
    }

    /// Rules are explored side by side and items are sized one by one, so a slow folder
    /// (an external disk, a pending privacy prompt) only holds back itself.
    /// `update` receives the merged result and the progress after each step.
    @concurrent
    static func scan(
        _ environment: CleanupEnvironment,
        rules: [CleanupRule] = rules,
        update: @escaping @Sendable (CleanupScanResult, Double) -> Void = { _, _ in }
    ) async -> CleanupScanResult {
        var environment = environment
        environment.home = environment.home.resolvingSymlinksInPath()
        let settled = environment
        var sized = [CleanupScanResult](repeating: CleanupScanResult(), count: rules.count)
        var claims = [[String]](repeating: [], count: rules.count)
        await withTaskGroup(of: ScanEvent.self) { group in
            for (index, rule) in rules.enumerated() {
                group.addTask {
                    .found(index, await BlockingIO.run { candidates(for: rule, environment: settled, isCancelled: $0) })
                }
            }
            var queue: [(Int, CleanupItem)] = []
            var running = 0
            var steps = 0
            var expectedSteps = rules.count
            while let event = await group.next() {
                steps += 1
                switch event {
                case .found(let index, let result):
                    claims[index] = result.items.map(\.url.path)
                    sized[index].unreadableLocations += result.unreadableLocations
                    queue += result.items.map { (index, $0) }
                    expectedSteps += result.items.count
                case .sized(let index, var item, let usage):
                    running -= 1
                    if !usage.isReadable {
                        sized[index].unreadableLocations += 1
                    } else if usage.bytes > 0 {
                        item.bytes = usage.bytes
                        sized[index].items.append(item)
                    }
                }
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                while running < 6, !queue.isEmpty {
                    let (index, item) = queue.removeFirst()
                    running += 1
                    group.addTask {
                        .sized(index, item, await BlockingIO.run { DirectorySizer.usage(of: item.url, isCancelled: $0) })
                    }
                }
                if steps % 8 == 0 || running == 0 {
                    update(merge(sized, claims: claims), Double(steps) / Double(expectedSteps))
                }
            }
        }
        return merge(sized, claims: claims)
    }

    /// Items found by the rules, not sized yet.
    static func candidates(_ environment: CleanupEnvironment, rules: [CleanupRule] = rules) -> CleanupScanResult {
        let perRule = rules.map { candidates(for: $0, environment: environment) }
        return merge(perRule, claims: perRule.map { $0.items.map(\.url.path) })
    }

    /// Results of each rule, in rule order: a path found by an earlier rule is dropped from later ones.
    static func merge(_ perRule: [CleanupScanResult], claims: [[String]]) -> CleanupScanResult {
        var merged = CleanupScanResult()
        var claimed: [String] = []
        for (result, paths) in zip(perRule, claims) {
            merged.items += result.items.filter { item in
                let path = item.url.path
                return !claimed.contains { $0 == path || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
            }
            merged.unreadableLocations += result.unreadableLocations
            claimed += paths
        }
        merged.items.sort { $0.bytes > $1.bytes }
        return merged
    }

    static func candidates(
        for rule: CleanupRule,
        environment: CleanupEnvironment,
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) -> CleanupScanResult {
        var result = CleanupScanResult()
        var found: [URL] = []
        for root in roots(of: rule, home: environment.home) {
            do {
                switch rule.scope {
                case .folder:
                    _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
                    found.append(root)
                case .eachChild:
                    found += try FileManager.default
                        .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                        .filter { !$0.lastPathComponent.hasPrefix(".") }
                case .buildArtifacts:
                    found += buildArtifacts(under: root, isCancelled: isCancelled)
                }
            } catch {
                if isPermissionError(error) { result.unreadableLocations += 1 }
            }
        }
        result.items = found.compactMap { url in
            let url = url.standardizedFileURL
            guard !environment.isProtected(url) else { return nil }
            return item(for: url, rule: rule, environment: environment)
        }
        return result
    }

    static func item(for url: URL, rule: CleanupRule, environment: CleanupEnvironment) -> CleanupItem? {
        let name = url.lastPathComponent
        if rule.installersOnly, !isInstaller(url, installedApps: environment.installedApps) { return nil }
        let lastUsed = lastUse(of: url, includingParent: rule.scope == .buildArtifacts)
        let ageDays = lastUsed.map { environment.now.timeIntervalSince($0) / 86_400 } ?? 0
        if let minimum = rule.minimumAgeDays, ageDays < Double(minimum) { return nil }

        var item = CleanupItem(url: url, category: rule.category, title: name, lastUsed: lastUsed, isRecommended: false)
        switch rule.selection {
        case .always: item.isRecommended = true
        case .never: item.isRecommended = false
        case .olderThan(let days): item.isRecommended = ageDays >= Double(days)
        }
        switch rule.category {
        case .appCaches:
            item.title = environment.appName(name) ?? name
            item.isAppRunning = isRunning(name, in: environment.runningApps)
            if item.isAppRunning { item.isRecommended = false }
        case .developer where rule.scope == .buildArtifacts:
            item.title = "\(url.deletingLastPathComponent().lastPathComponent)/\(name)"
        case .developer where url.deletingLastPathComponent().lastPathComponent == "DerivedData":
            item.title = derivedDataProjectName(name)
        default:
            break
        }
        return item
    }

    static func isInstaller(_ url: URL, installedApps: Set<String>) -> Bool {
        let ext = url.pathExtension.lowercased()
        if installerExtensions.contains(ext) { return true }
        guard ext == "zip" else { return false }
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        if base.contains("install") || base.contains("setup") { return true }
        let words = base.split(whereSeparator: { !$0.isLetter && $0 != " " })
        guard let first = words.first?.trimmingCharacters(in: .whitespaces), first.count >= 3 else { return false }
        return installedApps.contains(first) || installedApps.contains(first.replacingOccurrences(of: " ", with: ""))
    }

    static func isRunning(_ folderName: String, in runningApps: Set<String>) -> Bool {
        let name = folderName.lowercased()
        return runningApps.contains(name) || runningApps.contains { name.hasPrefix($0 + ".") && $0.contains(".") }
    }

    /// Xcode names DerivedData folders `<Project>-<28 letters>`.
    static func derivedDataProjectName(_ folderName: String) -> String {
        guard let dash = folderName.lastIndex(of: "-"),
              folderName.distance(from: dash, to: folderName.endIndex) == 29 else { return folderName }
        return String(folderName[..<dash])
    }

    static func lastUse(of url: URL, includingParent: Bool) -> Date? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
        var urls = [url]
        if includingParent { urls.append(url.deletingLastPathComponent()) }
        return urls.compactMap { try? $0.resourceValues(forKeys: keys) }
            .flatMap { [$0.contentModificationDate, $0.creationDate] }
            .compactMap { $0 }
            .max()
    }

    static func buildArtifacts(under root: URL, maxDepth: Int = 5, isCancelled: () -> Bool = { Task.isCancelled }) -> [URL] {
        let markers = ["node_modules": "package.json", ".build": "Package.swift", "target": "Cargo.toml"]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            guard !isCancelled() else { break }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let name = url.lastPathComponent
            if let marker = markers[name] {
                enumerator.skipDescendants()
                if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(marker).path) {
                    found.append(url)
                }
            } else if name.hasPrefix(".") || enumerator.level >= maxDepth {
                enumerator.skipDescendants()
            }
        }
        return found
    }

    /// Existing roots of a rule, symlinks resolved, each physical folder once. Project roots also
    /// follow their symlinked subfolders, since dev folders often point to an external disk.
    static func roots(of rule: CleanupRule, home: URL) -> [URL] {
        var urls = rule.paths.map { home.appendingPathComponent($0).resolvingSymlinksInPath() }
        if rule.scope == .buildArtifacts {
            urls += urls.flatMap { root in
                ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [])
                    .filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true }
                    .map { $0.resolvingSymlinksInPath() }
            }
        }
        var seen = Set<[UInt64]>()
        let unique = urls.filter { url in
            var info = stat()
            return stat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
                && seen.insert([UInt64(info.st_dev), info.st_ino]).inserted
        }
        return unique.filter { url in !unique.contains { url.path.hasPrefix($0.path + "/") } }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError { return true }
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(underlying?.code)
    }
}
