import Foundation
import Testing
@testable import RadixCore

struct DuplicateFinderTests {
    private func write(_ byte: UInt8, count: Int = 200_000, to url: URL, tail: UInt8? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(repeating: byte, count: count)
        if let tail { data[count / 2] = tail }
        try data.write(to: url)
    }

    private func scan(_ root: URL, minimumSize: Int64 = 100_000, home: URL? = nil, includesLibrary: Bool = false) async throws -> DuplicateScanResult {
        try await DuplicateFinder.scan(DuplicateScanOptions(
            roots: [root],
            minimumSize: minimumSize,
            includesLibrary: includesLibrary,
            home: home ?? root
        ))
    }

    @Test
    func identicalFilesAreGroupedAndLookalikesAreNot() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(1, to: root.appending(path: "a.bin"))
        try write(1, to: root.appending(path: "sub/b.bin"))
        try write(1, to: root.appending(path: "c.bin"), tail: 9)
        try write(2, count: 300_000, to: root.appending(path: "other.bin"))

        let result = try await scan(root)

        #expect(result.groups.count == 1)
        #expect(Set(result.groups[0].files.map(\.url.lastPathComponent)) == ["a.bin", "b.bin"])
        #expect(result.groups[0].reclaimableBytes == 200_000)
        #expect(result.filesSeen == 4)
    }

    @Test
    func hardLinksPackagesHiddenAndSmallFilesAreSkipped() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "a.bin")
        try write(3, to: original)
        try FileManager.default.linkItem(at: original, to: root.appending(path: "hardlink.bin"))
        try write(3, to: root.appending(path: "Tool.app/Contents/a.bin"))
        try write(3, to: root.appending(path: ".hidden/a.bin"))
        try write(3, to: root.appending(path: "Library/a.bin"))
        try write(4, count: 50_000, to: root.appending(path: "small1.bin"))
        try write(4, count: 50_000, to: root.appending(path: "small2.bin"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link.bin"), withDestinationURL: original)

        #expect(try await scan(root).groups.isEmpty)
        #expect(try await scan(root, minimumSize: 10_000).groups.map(\.size) == [50_000])
        let withLibrary = try await scan(root, includesLibrary: true)
        #expect(withLibrary.groups.first.map { Set($0.files.map(\.url.lastPathComponent)) } == ["a.bin"])
        #expect(withLibrary.groups.first?.files.count == 2)
    }

    @Test
    func clonesShareStorageAndFreeNothing() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "a.bin")
        try write(5, to: source)
        guard clonefile(source.path, root.appending(path: "clone.bin").path, 0) == 0 else { return }

        let group = try #require(try await scan(root).groups.first)

        #expect(group.files.count == 2)
        #expect(group.reclaimableBytes == 0)
        #expect(group.files.allSatisfy(group.sharesStorage))
        var selection = DuplicateSelection()
        selection.apply(.oldest, to: [group], downloads: root)
        #expect(selection.selected.isEmpty)
    }

    @Test
    func keepRulesPickTheExpectedCopy() {
        let downloads = URL(filePath: "/Users/x/Downloads")
        let old = DuplicateFile(url: URL(filePath: "/Users/x/Downloads/a"), size: 10, modified: .distantPast, inode: 1)
        let new = DuplicateFile(url: URL(filePath: "/Users/x/Documents/deep/a"), size: 10, modified: .now, inode: 2)
        let short = DuplicateFile(url: URL(filePath: "/Users/x/a"), size: 10, modified: Date(timeIntervalSince1970: 100), inode: 3)
        let group = DuplicateGroup(files: [old, new, short])

        #expect(DuplicateKeepRule.oldest.keeper(of: group, downloads: downloads) == old)
        #expect(DuplicateKeepRule.newest.keeper(of: group, downloads: downloads) == new)
        #expect(DuplicateKeepRule.shortestPath.keeper(of: group, downloads: downloads) == short)
        #expect(DuplicateKeepRule.outsideDownloads.keeper(of: group, downloads: downloads) == short)

        var selection = DuplicateSelection()
        selection.apply(.newest, to: [group], downloads: downloads)
        #expect(selection.selected == [old.url, short.url])
        #expect(selection.reclaimableBytes(in: [group]) == 20)
    }

    @Test
    func selectionNeverTakesEveryCopy() {
        let files = (1...3).map { DuplicateFile(url: URL(filePath: "/tmp/\($0)"), size: 10, modified: .now, inode: UInt64($0)) }
        let group = DuplicateGroup(files: files)
        var selection = DuplicateSelection()
        for rule in DuplicateKeepRule.allCases {
            selection.apply(rule, to: [group], downloads: URL(filePath: "/tmp/Downloads"))
            #expect(selection.selectedCount(in: [group]) == 2)
        }

        for file in files { selection.toggle(file, in: group) }
        for file in files { selection.toggle(file, in: group) }

        #expect(selection.selectedCount(in: [group]) == 2)
        #expect(!selection.canSelect(files.first { !selection.contains($0) }!, in: group))
    }

    @Test
    func trashPlanSkipsFilesChangedSinceTheScan() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(6, to: root.appending(path: "a.bin"))
        try write(6, to: root.appending(path: "b.bin"))
        try write(6, to: root.appending(path: "c.bin"))
        let group = try #require(try await scan(root).groups.first)
        var selection = DuplicateSelection()
        selection.apply(.shortestPath, to: [group], downloads: root)
        let changed = try #require(group.files.first { selection.contains($0) })
        try write(7, to: changed.url)

        let plan = selection.trashPlan(in: [group])

        #expect(plan.skipped == [changed.url])
        #expect(plan.items.count == 1)
        #expect(!plan.items.contains { $0.url == changed.url })
    }
}
