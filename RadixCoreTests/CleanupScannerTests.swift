import Foundation
import Testing
@testable import RadixCore

struct CleanupScannerTests {
    private let now = Date()

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanupScannerTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @discardableResult
    private func write(_ relative: String, in home: URL, bytes: Int = 8_192, daysOld: Double = 0) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        try age(url, days: daysOld)
        return url
    }

    private func age(_ url: URL, days: Double) throws {
        let date = now.addingTimeInterval(-days * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
    }

    private func environment(_ home: URL) -> CleanupEnvironment {
        var environment = CleanupEnvironment(home: home, now: now)
        environment.installedApps = ["rectangle"]
        environment.runningApps = ["com.example.running"]
        environment.appName = { $0 == "com.example.editor" ? "Editor" : nil }
        environment.isProtected = { _ in false }
        return environment
    }

    private func items(_ home: URL) -> [String: CleanupItem] {
        let result = CleanupScanner.candidates(environment(home))
        return Dictionary(uniqueKeysWithValues: result.items.map {
            (String($0.url.path.dropFirst(home.path.count + 1)), $0)
        })
    }

    @Test
    func testInstallersFollowExtensionsAndAgeThreshold() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("Downloads/Old.dmg", in: home, daysOld: 10)
        try write("Downloads/New.pkg", in: home, daysOld: 2)
        try write("Downloads/Rectangle0.80.zip", in: home, daysOld: 30)
        try write("Downloads/photos.zip", in: home, daysOld: 30)
        try write("Desktop/Tool.xip", in: home, daysOld: 8)

        let found = items(home)
        #expect(found["Downloads/Old.dmg"]?.category == .installers)
        #expect(found["Downloads/Old.dmg"]?.isRecommended == true)
        #expect(found["Downloads/New.pkg"]?.category == .installers)
        #expect(found["Downloads/New.pkg"]?.isRecommended == false)
        #expect(found["Downloads/Rectangle0.80.zip"]?.category == .installers)
        #expect(found["Desktop/Tool.xip"]?.isRecommended == true)
        #expect(found["Downloads/photos.zip"] == nil, "A recent ordinary zip is neither an installer nor an old download")
    }

    @Test
    func testOldDownloadsNeedNinetyDaysAndAreNeverSelected() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("Downloads/report.pdf", in: home, daysOld: 120)
        try write("Downloads/recent.pdf", in: home, daysOld: 20)
        try write("Downloads/.DS_Store", in: home, daysOld: 400)
        try write("Downloads/Ancient.dmg", in: home, daysOld: 400)

        let found = items(home)
        #expect(found["Downloads/report.pdf"]?.category == .oldDownloads)
        #expect(found["Downloads/report.pdf"]?.isRecommended == false)
        #expect(found["Downloads/recent.pdf"] == nil)
        #expect(found["Downloads/.DS_Store"] == nil)
        #expect(found["Downloads/Ancient.dmg"]?.category == .installers, "An installer is listed once, as an installer")
    }

    @Test
    func testCachesAreClaimedOnceAndRunningAppsStayUnselected() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("Library/Caches/com.example.editor/a", in: home)
        try write("Library/Caches/com.example.running.helper/a", in: home)
        try write("Library/Caches/Homebrew/a", in: home)
        try write("Library/Developer/Xcode/DerivedData/Vrac-abcdefghijklmnopqrstuvwxyzab/a", in: home)
        try write("Library/Developer/Xcode/Archives/2026-01-01/a", in: home)
        try write("Library/Logs/DiagnosticReports/crash.ips", in: home)
        try write("Library/Logs/App/app.log", in: home)

        let found = items(home)
        #expect(found["Library/Caches/com.example.editor"]?.title == "Editor")
        #expect(found["Library/Caches/com.example.editor"]?.isRecommended == true)
        #expect(found["Library/Caches/com.example.running.helper"]?.isAppRunning == true)
        #expect(found["Library/Caches/com.example.running.helper"]?.isRecommended == false)
        #expect(found["Library/Caches/Homebrew"]?.category == .developer)
        #expect(found["Library/Developer/Xcode/DerivedData/Vrac-abcdefghijklmnopqrstuvwxyzab"]?.title == "Vrac")
        #expect(found["Library/Developer/Xcode/Archives/2026-01-01"]?.isRecommended == false)
        #expect(found["Library/Logs/DiagnosticReports/crash.ips"]?.category == .logs)
        #expect(found["Library/Logs/DiagnosticReports"] == nil, "The folder is not listed again around its claimed children")
        #expect(found["Library/Logs/App"]?.category == .logs)
        #expect(Set(found.keys).count == found.count)
    }

    @Test
    func testStaleBuildArtifactsNeedTheirProjectMarker() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("Dev/web/package.json", in: home, daysOld: 60)
        try write("Dev/web/node_modules/left-pad/index.js", in: home, daysOld: 60)
        try write("Dev/fresh/package.json", in: home, daysOld: 1)
        try write("Dev/fresh/node_modules/x/index.js", in: home, daysOld: 1)
        try write("Dev/random/target/file", in: home, daysOld: 60)
        for folder in ["Dev/web/node_modules", "Dev/web", "Dev/random/target", "Dev/random"] {
            try age(home.appendingPathComponent(folder), days: 60)
        }

        let found = items(home)
        #expect(found["Dev/web/node_modules"]?.category == .developer)
        #expect(found["Dev/web/node_modules"]?.isRecommended == false)
        #expect(found["Dev/web/node_modules"]?.title == "web/node_modules")
        #expect(found["Dev/fresh/node_modules"] == nil)
        #expect(found["Dev/random/target"] == nil)
    }

    @Test
    func testBuildArtifactsAreFoundThroughSymlinkedProjectFolders() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("External/app/Package.swift", in: home, daysOld: 45)
        try write("External/app/.build/debug/app", in: home, daysOld: 45)
        for folder in ["External/app/.build", "External/app"] {
            try age(home.appendingPathComponent(folder), days: 45)
        }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Dev"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("Dev/Perso"),
            withDestinationURL: home.appendingPathComponent("External")
        )

        let found = items(home)
        #expect(found["External/app/.build"]?.category == .developer)
        #expect(found.count == 1)
    }

    @Test
    func testScanSizesItemsAndDropsProtectedOnes() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("Library/Caches/com.example.big/blob", in: home, bytes: 200_000)
        try write("Library/Caches/com.example.blocked/blob", in: home, bytes: 50_000)
        var environment = environment(home)
        environment.isProtected = { $0.lastPathComponent == "com.example.blocked" }

        let result = await CleanupScanner.scan(environment)
        #expect(result.items.map(\.url.lastPathComponent) == ["com.example.big"])
        #expect(result.items.first?.bytes ?? 0 >= 200_000)
    }

    @Test
    func testDirectorySizerSkipsExcludedFolders() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("a/keep", in: home, bytes: 100_000)
        let skipped = try write("a/skip/drop", in: home, bytes: 300_000)

        let all = DirectorySizer.usage(of: home.appendingPathComponent("a"))
        let partial = DirectorySizer.usage(
            of: home.appendingPathComponent("a"),
            excluding: [skipped.deletingLastPathComponent().path]
        )
        #expect(all.bytes >= 400_000)
        #expect(partial.bytes >= 100_000 && partial.bytes < 300_000)
        #expect(DirectorySizer.usage(of: home.appendingPathComponent("missing")).isReadable == false)
    }
}
