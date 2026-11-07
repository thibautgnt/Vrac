import AVFoundation
import Foundation

nonisolated enum CompressVideoTranscoder {
    enum Failure: Error {
        case unsupported
        case exportFailed
    }

    static func outputExtension(for original: URL) -> String {
        ["mp4", "m4v"].contains(original.pathExtension.lowercased()) ? "mp4" : "mov"
    }

    static func info(for url: URL) async -> CompressMediaInfo? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform, frameRate, dataRate, formats) = try? await track.load(
                  .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions),
              let duration = try? await asset.load(.duration) else { return nil }
        let display = size.applying(transform)
        return CompressMediaInfo(
            kind: .video,
            bytes: CompressPipeline.fileSize(url),
            width: Int(abs(display.width).rounded()),
            height: Int(abs(display.height).rounded()),
            duration: duration.seconds.isFinite ? duration.seconds : 0,
            codec: formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "",
            bitsPerSecond: Double(dataRate),
            framesPerSecond: Double(frameRate)
        )
    }

    static func estimate(_ url: URL, preset: CompressVideoPreset) async -> Int64? {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: preset.exportPresetName) else { return nil }
        session.outputFileType = fileType(for: outputExtension(for: url))
        guard let bytes = try? await session.estimatedOutputFileLengthInBytes, bytes > 0 else { return nil }
        return bytes
    }

    static func export(
        _ url: URL,
        to output: URL,
        preset: CompressVideoPreset,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let created = AVAssetExportSession(asset: asset, presetName: preset.exportPresetName) else {
            throw Failure.unsupported
        }
        created.metadata = await metadataKeepingCreationDate(of: asset)
        let box = SessionBox(session: created)
        let type = fileType(for: output.pathExtension)
        if #available(macOS 15, *) {
            let watcher = Task {
                for await state in box.session.states(updateInterval: 0.25) {
                    if case .exporting(let exportProgress) = state { progress(exportProgress.fractionCompleted) }
                }
            }
            defer { watcher.cancel() }
            try await box.session.export(to: output, as: type)
        } else {
            box.session.outputURL = output
            box.session.outputFileType = type
            let watcher = Task {
                while !Task.isCancelled {
                    progress(Double(box.session.progress))
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { watcher.cancel() }
            await withTaskCancellationHandler {
                await box.session.export()
            } onCancel: {
                box.session.cancelExport()
            }
            try Task.checkCancellation()
            guard box.session.status == .completed else { throw box.session.error ?? Failure.exportFailed }
        }
    }

    /// Source metadata (location, camera...) plus an explicit creation date, which the export would otherwise reset to now.
    private static func metadataKeepingCreationDate(of asset: AVURLAsset) async -> [AVMetadataItem] {
        var items = (try? await asset.load(.metadata)) ?? []
        let hasDate = items.contains { $0.identifier == .quickTimeMetadataCreationDate || $0.identifier == .commonIdentifierCreationDate }
        if !hasDate, let creationDate = try? await asset.load(.creationDate), let value = try? await creationDate.load(.value) {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataCreationDate
            item.value = value
            items.append(item)
        }
        return items
    }

    static func verify(_ output: URL, original: CompressMediaInfo, preset: CompressVideoPreset) async -> Bool {
        let asset = AVURLAsset(url: output)
        guard let isPlayable = try? await asset.load(.isPlayable), isPlayable,
              let info = await info(for: output),
              info.duration > 0, abs(info.duration - original.duration) <= 1 else { return false }
        return CompressPipeline.hasExpectedShape(width: info.width, height: info.height, original: original, box: preset.maxSize)
    }

    /// AVAssetExportSession is not Sendable, yet reading its progress and cancelling it from another task is supported.
    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(session: AVAssetExportSession) { self.session = session }
    }

    private static func fileType(for pathExtension: String) -> AVFileType {
        pathExtension.lowercased() == "mp4" ? .mp4 : .mov
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .macOSRoman)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}
