import Foundation
import UniformTypeIdentifiers

nonisolated enum CompressMediaKind: Sendable, Hashable {
    case video
    case image

    init?(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .movie) || type.conforms(to: .video) {
            self = .video
        } else if type.conforms(to: .image) {
            self = .image
        } else {
            return nil
        }
    }
}

nonisolated struct CompressMediaInfo: Sendable, Hashable {
    var kind: CompressMediaKind
    var bytes: Int64
    var width: Int
    var height: Int
    var duration: Double = 0
    /// FourCC for videos ("avc1", "hvc1"...), uniform type identifier for images.
    var codec: String
    var bitsPerSecond: Double = 0
    var framesPerSecond: Double = 0

    var isHEVC: Bool {
        ["hvc1", "hev1"].contains(codec) || codec == UTType.heic.identifier || codec == UTType.heif.identifier
    }
}

nonisolated enum CompressVideoPreset: String, CaseIterable, Identifiable, Sendable {
    case highestQuality
    case hd1080
    case uhd4K

    var id: String { rawValue }

    var exportPresetName: String {
        switch self {
        case .highestQuality: "AVAssetExportPresetHEVCHighestQuality"
        case .hd1080: "AVAssetExportPresetHEVC1920x1080"
        case .uhd4K: "AVAssetExportPresetHEVC3840x2160"
        }
    }

    /// Box the preset fits the picture in; the presets never upscale.
    var maxSize: CompressBox? {
        switch self {
        case .highestQuality: nil
        case .hd1080: CompressBox(long: 1920, short: 1080)
        case .uhd4K: CompressBox(long: 3840, short: 2160)
        }
    }
}

nonisolated struct CompressBox: Sendable, Hashable {
    var long: Int
    var short: Int

    static func square(_ side: Int) -> CompressBox { CompressBox(long: side, short: side) }
}

nonisolated struct CompressSettings: Sendable, Hashable {
    var videoPreset: CompressVideoPreset = .highestQuality
    var imageQuality: Double = 0.8
    var imageMaxPixelSize: Int?

    func cacheKey(for kind: CompressMediaKind) -> String {
        switch kind {
        case .video: videoPreset.rawValue
        case .image: "\(Int((imageQuality * 100).rounded()))-\(imageMaxPixelSize ?? 0)"
        }
    }
}

nonisolated enum CompressRules {
    static let minimumVideoBytes: Int64 = 50_000_000
    static let minimumImageBytes: Int64 = 5_000_000
    static let minimumGain = 0.10
    /// Above this many bits per pixel and per frame, even HEVC is worth re-encoding (iPhone HEVC sits around 0.1).
    static let maximumHEVCBitsPerPixel = 0.25
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "bmp"]

    static func isScanCandidate(url: URL, bytes: Int64) -> Bool {
        guard !url.deletingPathExtension().lastPathComponent.contains(outputMarker) else { return false }
        switch CompressMediaKind(url: url) {
        case .video: return bytes > minimumVideoBytes
        case .image: return bytes > minimumImageBytes && imageExtensions.contains(url.pathExtension.lowercased())
        case nil: return false
        }
    }

    static func isWorthCompressing(_ info: CompressMediaInfo) -> Bool {
        switch info.kind {
        case .video:
            guard info.bytes > minimumVideoBytes else { return false }
            return !info.isHEVC || bitsPerPixel(info) > maximumHEVCBitsPerPixel
        case .image:
            return info.bytes > minimumImageBytes && !info.isHEVC
        }
    }

    static func bitsPerPixel(_ info: CompressMediaInfo) -> Double {
        let pixelsPerSecond = Double(info.width * info.height) * (info.framesPerSecond > 0 ? info.framesPerSecond : 30)
        return pixelsPerSecond > 0 ? info.bitsPerSecond / pixelsPerSecond : 0
    }

    static func isWorthKeeping(originalBytes: Int64, outputBytes: Int64) -> Bool {
        outputBytes > 0 && Double(outputBytes) <= Double(originalBytes) * (1 - minimumGain)
    }

    /// Longest side once the picture is fitted in `box` without upscaling.
    static func expectedLongestSide(of info: CompressMediaInfo, box: CompressBox?) -> Int {
        let longest = max(info.width, info.height)
        let shortest = min(info.width, info.height)
        guard let box, longest > 0, shortest > 0 else { return longest }
        let scale = min(1, Double(box.long) / Double(longest), Double(box.short) / Double(shortest))
        return Int((Double(longest) * scale).rounded())
    }

    static let outputMarker = "(compressé"

    static func outputURL(
        for original: URL,
        pathExtension: String,
        isTaken: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let folder = original.deletingLastPathComponent()
        let base = original.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let suffix = index == 1 ? "\(outputMarker))" : "\(outputMarker) \(index))"
            let candidate = folder.appendingPathComponent("\(base) \(suffix)").appendingPathExtension(pathExtension)
            if !isTaken(candidate) { return candidate }
            index += 1
        }
    }

    /// Name the output takes when it replaces the original: same base name, new extension.
    static func replacementURL(for original: URL, output: URL) -> URL {
        original.deletingPathExtension().appendingPathExtension(output.pathExtension)
    }
}
