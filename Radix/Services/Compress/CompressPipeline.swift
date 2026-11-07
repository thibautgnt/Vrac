import Foundation

nonisolated struct CompressResult: Sendable, Equatable {
    var output: URL
    var originalBytes: Int64
    var outputBytes: Int64
    var replacedOriginal: Bool
    var trashFailure: String?

    var savedBytes: Int64 { originalBytes - outputBytes }
}

nonisolated enum CompressOutcome: Sendable, Equatable {
    case compressed(CompressResult)
    case alreadyOptimized
    case verificationFailed
}

nonisolated enum CompressPipeline {
    /// Runs after the transcoder wrote `output`: drops it when the gain is too small or it fails
    /// verification, copies the original's dates, and only then may trash the original.
    static func finish(
        original: URL,
        output: URL,
        replaceOriginal: Bool,
        verify: (URL) async -> Bool,
        trash: (URL) -> String?,
        fileManager: FileManager = .default
    ) async -> CompressOutcome {
        let originalBytes = fileSize(original)
        let outputBytes = fileSize(output)
        guard CompressRules.isWorthKeeping(originalBytes: originalBytes, outputBytes: outputBytes) else {
            try? fileManager.removeItem(at: output)
            return .alreadyOptimized
        }
        guard await verify(output) else {
            try? fileManager.removeItem(at: output)
            return .verificationFailed
        }
        copyDates(from: original, to: output, fileManager: fileManager)

        var result = CompressResult(output: output, originalBytes: originalBytes, outputBytes: outputBytes, replacedOriginal: false)
        guard replaceOriginal else { return .compressed(result) }
        if let failure = trash(original) {
            result.trashFailure = failure
            return .compressed(result)
        }
        result.replacedOriginal = true
        let target = CompressRules.replacementURL(for: original, output: output)
        if (try? fileManager.moveItem(at: output, to: target)) != nil {
            result.output = target
        }
        return .compressed(result)
    }

    /// Transcodes into a scratch folder on the same volume and moves the result to `output` only once complete,
    /// so a crash or a quit never leaves a half-written file next to the original.
    static func write(
        _ output: URL,
        near original: URL,
        transcode: (URL) async throws -> Void,
        fileManager: FileManager = .default
    ) async throws {
        let scratch = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: original, create: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let partial = scratch.appendingPathComponent(output.lastPathComponent)
        try await transcode(partial)
        try Task.checkCancellation()
        try fileManager.moveItem(at: partial, to: output)
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static func copyDates(from original: URL, to output: URL, fileManager: FileManager = .default) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: original.path) else { return }
        var dates: [FileAttributeKey: Any] = [:]
        dates[.creationDate] = attributes[.creationDate]
        dates[.modificationDate] = attributes[.modificationDate]
        try? fileManager.setAttributes(dates, ofItemAtPath: output.path)
    }

    static func hasExpectedShape(width: Int, height: Int, original: CompressMediaInfo, box: CompressBox?) -> Bool {
        guard width > 0, height > 0, original.width > 0, original.height > 0 else { return false }
        let expectedLongest = CompressRules.expectedLongestSide(of: original, box: box)
        let ratio = Double(max(width, height)) / Double(min(width, height))
        let originalRatio = Double(max(original.width, original.height)) / Double(min(original.width, original.height))
        let tolerance = max(4, expectedLongest / 100)
        return abs(max(width, height) - expectedLongest) <= tolerance && abs(ratio - originalRatio) / originalRatio < 0.02
    }
}
