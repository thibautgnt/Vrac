import Foundation
import Testing
@testable import RadixCore

struct StorageOverviewTests {
    private let home = URL(fileURLWithPath: "/fixture/home")

    private func jobs() -> [OverviewJob] {
        let tree: [String: [String]] = [
            "/fixture/home": ["Documents", "Downloads", "Library", "Dev", ".zshrc", "Other"],
            "/fixture/home/Library": ["Caches", "Developer", "Mobile Documents"],
        ]
        let roots: [(OverviewCategory, [URL])] = [
            (.applications, [URL(fileURLWithPath: "/fixture/Applications")]),
            (.documents, [home.appendingPathComponent("Documents")]),
            (.downloads, [home.appendingPathComponent("Downloads")]),
            (.iCloud, [home.appendingPathComponent("Library/Mobile Documents")]),
            (.developer, [
                home.appendingPathComponent("Library/Developer"),
                home.appendingPathComponent("Documents/Code"),
                home.appendingPathComponent("Dev"),
                home.appendingPathComponent("Dev/inner"),
            ]),
            (.mail, [home.appendingPathComponent("Library/Mail")]),
        ]
        return OverviewAccounting.jobs(
            home: home,
            roots: roots,
            isEligible: { !$0.path.hasSuffix("/Mail") },
            children: { url in (tree[url.path] ?? []).map { url.appendingPathComponent($0) } }
        )
    }

    @Test
    func testEveryPathBelongsToExactlyOneJob() {
        let jobs = jobs()
        let probes = [
            "/fixture/Applications/Safari.app/Contents/Info.plist",
            "/fixture/home/Documents/letter.pages",
            "/fixture/home/Documents/Code/app/main.swift",
            "/fixture/home/Dev/inner/x",
            "/fixture/home/Library/Caches/com.example/blob",
            "/fixture/home/Library/Mobile Documents/doc",
            "/fixture/home/.zshrc",
            "/fixture/home/Other/file",
        ]
        for probe in probes {
            #expect(jobs.filter { $0.contains(probe) }.count == 1, "\(probe) must be counted exactly once")
        }
        let category = { OverviewAccounting.category(of: URL(fileURLWithPath: $0), in: jobs) }
        #expect(category("/fixture/home/Documents/Code/app/main.swift") == .developer)
        #expect(category("/fixture/home/Documents/letter.pages") == .documents)
        #expect(category("/fixture/home/Library/Caches/com.example/blob") == .otherUser)
        #expect(category("/elsewhere/file") == nil)
    }

    @Test
    func testIneligibleRootsAndSplitFoldersAreNotJobs() {
        let paths = Set(jobs().map(\.url.path))
        #expect(!paths.contains("/fixture/home/Library/Mail"))
        #expect(!paths.contains("/fixture/home"))
        #expect(!paths.contains("/fixture/home/Library"))
        #expect(!paths.contains("/fixture/home/Dev/inner"), "A root nested in a root of the same category is not measured twice")
        #expect(jobs().first { $0.url.path == "/fixture/home/Documents" }?.excluded == ["/fixture/home/Documents/Code"])
    }

    @Test
    func testBreakdownCarvesReclaimableAndNeverGoesNegative() {
        let measured: [OverviewCategory: Int64] = [.documents: 400, .developer: 300, .otherUser: 200]
        let normal = OverviewAccounting.breakdown(
            measured: measured,
            used: 1_000,
            reclaimable: [.developer: 120, .otherUser: 500]
        )
        #expect(normal.kept[.system] == 100)
        #expect(normal.kept[.developer] == 180)
        #expect(normal.kept[.otherUser] == 0)
        #expect(normal.reclaimable == 320)
        #expect(normal.kept.values.reduce(0, +) + normal.reclaimable == 1_000)

        let overcounted = OverviewAccounting.breakdown(measured: measured, used: 600, reclaimable: [:])
        #expect(overcounted.kept[.system] == 0)
        #expect(overcounted.kept.values.allSatisfy { $0 >= 0 })
    }
}
