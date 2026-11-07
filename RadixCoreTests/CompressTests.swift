import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RadixCore

struct CompressRulesTests {
    private func video(_ bytes: Int64, codec: String, bitsPerSecond: Double = 10_000_000) -> CompressMediaInfo {
        CompressMediaInfo(kind: .video, bytes: bytes, width: 1920, height: 1080, duration: 60, codec: codec, bitsPerSecond: bitsPerSecond, framesPerSecond: 30)
    }

    @Test
    func testVideoCandidatesNeedSizeAndAnOldCodecOrAHighBitrate() {
        #expect(CompressRules.isWorthCompressing(video(80_000_000, codec: "avc1")))
        #expect(CompressRules.isWorthCompressing(video(80_000_000, codec: "apcn")))
        #expect(!CompressRules.isWorthCompressing(video(40_000_000, codec: "avc1")))
        #expect(!CompressRules.isWorthCompressing(video(80_000_000, codec: "hvc1", bitsPerSecond: 12_000_000)))
        #expect(CompressRules.isWorthCompressing(video(80_000_000, codec: "hvc1", bitsPerSecond: 200_000_000)))
    }

    @Test
    func testImageCandidatesNeedSizeAndANonHEICFormat() {
        let jpeg = CompressMediaInfo(kind: .image, bytes: 8_000_000, width: 4000, height: 3000, codec: UTType.jpeg.identifier)
        var heic = jpeg
        heic.codec = UTType.heic.identifier
        var small = jpeg
        small.bytes = 2_000_000
        #expect(CompressRules.isWorthCompressing(jpeg))
        #expect(!CompressRules.isWorthCompressing(heic))
        #expect(!CompressRules.isWorthCompressing(small))
    }

    @Test
    func testScanFilterUsesExtensionSizeAndSkipsOutputs() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        #expect(CompressRules.isScanCandidate(url: folder.appendingPathComponent("a.mov"), bytes: 60_000_000))
        #expect(!CompressRules.isScanCandidate(url: folder.appendingPathComponent("a.mov"), bytes: 10_000_000))
        #expect(CompressRules.isScanCandidate(url: folder.appendingPathComponent("a.JPG"), bytes: 6_000_000))
        #expect(!CompressRules.isScanCandidate(url: folder.appendingPathComponent("a.heic"), bytes: 60_000_000))
        #expect(!CompressRules.isScanCandidate(url: folder.appendingPathComponent("a.pdf"), bytes: 60_000_000))
        #expect(!CompressRules.isScanCandidate(url: folder.appendingPathComponent("a (compressé).mov"), bytes: 60_000_000))
    }

    @Test
    func testGainThresholdAndExpectedSize() {
        #expect(CompressRules.isWorthKeeping(originalBytes: 1000, outputBytes: 900))
        #expect(!CompressRules.isWorthKeeping(originalBytes: 1000, outputBytes: 901))
        #expect(!CompressRules.isWorthKeeping(originalBytes: 1000, outputBytes: 0))
        let square = CompressMediaInfo(kind: .video, bytes: 1, width: 2000, height: 2000, codec: "avc1")
        #expect(CompressRules.expectedLongestSide(of: square, box: CompressVideoPreset.hd1080.maxSize) == 1080)
        #expect(CompressRules.expectedLongestSide(of: square, box: CompressVideoPreset.uhd4K.maxSize) == 2000)
    }

    @Test
    func testOutputNamesAvoidCollisions() throws {
        let folder = try CompressFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("Vacances.mp4")
        let first = CompressRules.outputURL(for: original, pathExtension: "mov")
        #expect(first.lastPathComponent == "Vacances (compressé).mov")
        try Data().write(to: first)
        #expect(CompressRules.outputURL(for: original, pathExtension: "mov").lastPathComponent == "Vacances (compressé 2).mov")
        #expect(CompressRules.replacementURL(for: original, output: first).lastPathComponent == "Vacances.mov")
    }
}

struct CompressPipelineTests {
    @Test
    func testHEICKeepsOrientationExifAndFileDates() async throws {
        let folder = try CompressFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try CompressFixtures.jpeg(in: folder)
        let info = try #require(CompressImageTranscoder.info(for: original))
        let output = CompressRules.outputURL(for: original, pathExtension: "heic")

        try await CompressImageTranscoder.transcode(original, to: output, quality: 0.8, maxPixelSize: nil)
        let outcome = await CompressPipeline.finish(
            original: original,
            output: output,
            replaceOriginal: false,
            verify: { await CompressImageTranscoder.verify($0, original: info, maxPixelSize: nil) },
            trash: { _ in Issue.record("must not trash"); return nil }
        )

        guard case .compressed(let result) = outcome else { Issue.record("\(outcome)"); return }
        #expect(result.output == output)
        #expect(result.savedBytes > 0)
        let properties = try CompressFixtures.properties(of: output)
        #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 640)
        let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == CompressFixtures.exifDate)
        #expect(properties[kCGImagePropertyGPSDictionary] != nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        #expect(attributes[.creationDate] as? Date == CompressFixtures.fileDate)
        #expect(attributes[.modificationDate] as? Date == CompressFixtures.fileDate)
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test
    func testMaxPixelSizeScalesAndKeepsOrientation() async throws {
        let folder = try CompressFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try CompressFixtures.jpeg(in: folder)
        let info = try #require(CompressImageTranscoder.info(for: original))
        let output = folder.appendingPathComponent("small.heic")

        try await CompressImageTranscoder.transcode(original, to: output, quality: 0.8, maxPixelSize: 320)

        let properties = try CompressFixtures.properties(of: output)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 320)
        #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
        #expect(await CompressImageTranscoder.verify(output, original: info, maxPixelSize: 320))
        #expect(!(await CompressImageTranscoder.verify(output, original: info, maxPixelSize: nil)))
    }

    @Test
    func testSmallGainIsDiscarded() async throws {
        let folder = try CompressFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("a.jpg")
        let output = folder.appendingPathComponent("a (compressé).heic")
        try Data(count: 1000).write(to: original)
        try Data(count: 950).write(to: output)

        let outcome = await CompressPipeline.finish(
            original: original, output: output, replaceOriginal: true,
            verify: { _ in true }, trash: { _ in Issue.record("must not trash"); return nil }
        )

        #expect(outcome == .alreadyOptimized)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test
    func testFailedVerificationNeverTrashesTheOriginal() async throws {
        let folder = try CompressFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("a.mov")
        let output = folder.appendingPathComponent("a (compressé).mov")
        try Data(count: 1000).write(to: original)
        try Data(count: 100).write(to: output)
        var trashed: [URL] = []

        let outcome = await CompressPipeline.finish(
            original: original, output: output, replaceOriginal: true,
            verify: { _ in false }, trash: { trashed.append($0); return nil }
        )

        #expect(outcome == .verificationFailed)
        #expect(trashed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test
    func testReplacementTrashesThenTakesTheOriginalName() async throws {
        let folder = try CompressFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("a.mov")
        let output = folder.appendingPathComponent("a (compressé).mov")
        try Data(count: 1000).write(to: original)
        try Data(count: 100).write(to: output)
        var trashed: [URL] = []

        let outcome = await CompressPipeline.finish(
            original: original, output: output, replaceOriginal: true,
            verify: { _ in true },
            trash: { url in
                trashed.append(url)
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        )

        #expect(trashed == [original])
        #expect(outcome == .compressed(CompressResult(output: original, originalBytes: 1000, outputBytes: 100, replacedOriginal: true)))
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test
    func testTrashFailureKeepsBothFiles() async throws {
        let folder = try CompressFixtures.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("a.mov")
        let output = folder.appendingPathComponent("a (compressé).mov")
        try Data(count: 1000).write(to: original)
        try Data(count: 100).write(to: output)

        let outcome = await CompressPipeline.finish(
            original: original, output: output, replaceOriginal: true,
            verify: { _ in true }, trash: { _ in "locked" }
        )

        guard case .compressed(let result) = outcome else { Issue.record("\(outcome)"); return }
        #expect(result.trashFailure == "locked")
        #expect(!result.replacedOriginal)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: output.path))
    }
}

enum CompressFixtures {
    static let exifDate = "2021:06:15 10:30:00"
    static let fileDate = Date(timeIntervalSince1970: 1_600_000_000)

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CompressTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 640x480 noisy JPEG tagged with orientation 6, an EXIF date and a GPS position.
    static func jpeg(in folder: URL) throws -> URL {
        let width = 640, height = 480
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 7
        for index in stride(from: 0, to: pixels.count, by: 4) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let x = (index / 4) % width
            pixels[index] = UInt8(x * 255 / width)
            pixels[index + 1] = UInt8(seed >> 24) / 4
            pixels[index + 2] = 128
            pixels[index + 3] = 255
        }
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let url = folder.appendingPathComponent("Photo.jpg")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 1.0,
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: exifDate],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 45.9, kCGImagePropertyGPSLatitudeRef: "N"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        try FileManager.default.setAttributes([.creationDate: fileDate, .modificationDate: fileDate], ofItemAtPath: url.path)
        return url
    }

    static func properties(of url: URL) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }
}
