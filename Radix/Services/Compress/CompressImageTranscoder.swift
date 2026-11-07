import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum CompressImageTranscoder {
    enum Failure: Error {
        case unreadable
        case encodingFailed
    }

    static func info(for url: URL) -> CompressMediaInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CompressMediaInfo(kind: .image, bytes: CompressPipeline.fileSize(url), width: width, height: height, codec: type)
    }

    /// HEIC data for the first image of `url`; EXIF, GPS and orientation travel with the image.
    @concurrent
    static func encode(_ url: URL, quality: Double, maxPixelSize: Int?) async throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw Failure.unreadable }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else {
            throw Failure.encodingFailed
        }
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let maxPixelSize {
            options[kCGImageDestinationImageMaxPixelSize] = maxPixelSize
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        return data as Data
    }

    static func transcode(_ url: URL, to output: URL, quality: Double, maxPixelSize: Int?) async throws {
        let data = try await encode(url, quality: quality, maxPixelSize: maxPixelSize)
        try Task.checkCancellation()
        try data.write(to: output, options: .withoutOverwriting)
    }

    @concurrent
    static func verify(_ output: URL, original: CompressMediaInfo, maxPixelSize: Int?) async -> Bool {
        guard let info = info(for: output),
              let source = CGImageSourceCreateWithURL(output as CFURL, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return false }
        return CompressPipeline.hasExpectedShape(width: info.width, height: info.height, original: original, box: maxPixelSize.map(CompressBox.square))
    }
}
