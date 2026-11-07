import Foundation
import Testing
@testable import RadixCore

struct RoomTrashTests {
    @Test
    func testProtectedPathsAreRefusedAndOthersTrashed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.bin")
        try Data(repeating: 1, count: 10_000).write(to: file)

        var trashed: [URL] = []
        let result = RoomTrash.moveToTrash(
            [RoomTrashItem(url: URL(fileURLWithPath: "/Applications"), bytes: 5), RoomTrashItem(url: file, bytes: 42)],
            trashItem: { trashed.append($0) }
        )

        #expect(trashed == [file])
        #expect(result.freedBytes == 42)
        #expect(result.failures.map(\.url.path) == ["/Applications"])
        #expect(RoomTrash.allocatedSize(of: root) >= 10_000)
    }
}
