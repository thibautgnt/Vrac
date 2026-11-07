import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct CompressRoomView: View {
    @ObservedObject private var model = CompressRoomModel.shared
    @State private var importsFiles = false
    @State private var isDropTargeted = false

    var body: some View {
        RoomPage(room: .compress, scrolls: false) {
            CompressPresetControls(model: model)
        } content: {
            if model.items.isEmpty {
                dropZone
                    .padding([.horizontal, .bottom], 28)
            } else {
                VStack(spacing: 0) {
                    summary
                        .padding(.horizontal, 28)
                        .padding(.bottom, 12)
                    list
                    CompressActionBar(model: model)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .fileImporter(isPresented: $importsFiles, allowedContentTypes: [.movie, .image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.stack")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(VracRoom.compress.tint.gradient)
            VStack(spacing: 6) {
                Text("Drop videos or photos here", tableName: "Compress")
                    .font(.title2.weight(.semibold))
                Text("They are re-encoded in HEVC or HEIC next to the originals. Nothing is deleted unless you ask for it.", tableName: "Compress")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: 10) {
                Button {
                    model.findCandidates()
                } label: {
                    Label(String(localized: "Find Candidates", table: "Compress"), systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .tint(VracRoom.compress.tint)
                .disabled(model.isScanning)
                Button(String(localized: "Choose Files…", table: "Compress")) { importsFiles = true }
            }
            .controlSize(.large)
            Group {
                if model.isScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for large videos and photos…", tableName: "Compress")
                    }
                } else if model.lastScanFoundNothing {
                    Text("No candidates in Movies, Desktop, Downloads or Documents.", tableName: "Compress")
                } else {
                    Text("Searches Movies, Desktop, Downloads and Documents, never inside a Photos library.", tableName: "Compress")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isDropTargeted ? VracRoom.compress.tint.opacity(0.08) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? VracRoom.compress.tint : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                )
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
    }

    private var summary: some View {
        HStack(alignment: .bottom, spacing: 32) {
            let results = model.results
            if model.potentialSavings > 0 || results.isEmpty {
                RoomStat(
                    value: RadixFormatters.size(model.potentialSavings),
                    caption: String(localized: "potential savings", table: "Compress"),
                    tint: VracRoom.compress.tint
                )
            }
            if !results.isEmpty {
                let freed = results.filter(\.replacedOriginal).reduce(0) { $0 + $1.savedBytes }
                let pending = results.filter { !$0.replacedOriginal }.reduce(0) { $0 + $1.savedBytes }
                if freed > 0 {
                    RoomStat(value: RadixFormatters.size(freed), caption: String(localized: "freed", table: "Compress"))
                }
                if pending > 0 {
                    RoomStat(value: RadixFormatters.size(pending), caption: String(localized: "to free by deleting the originals", table: "Compress"))
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                }
                Button(String(localized: "Find Candidates", table: "Compress"), systemImage: "magnifyingglass") {
                    model.findCandidates()
                }
                .disabled(model.isScanning)
                Button(String(localized: "Choose Files…", table: "Compress"), systemImage: "plus") { importsFiles = true }
            }
        }
    }

    private var list: some View {
        List {
            ForEach(model.items) { item in
                CompressItemRow(item: item, estimate: model.estimate(for: item), model: model)
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(VracRoom.compress.tint, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct CompressPresetControls: View {
    @ObservedObject var model: CompressRoomModel
    @State private var editsImages = false

    var body: some View {
        HStack(spacing: 10) {
            Picker(selection: $model.settings.videoPreset) {
                ForEach(CompressVideoPreset.allCases) { preset in
                    preset.title.tag(preset)
                }
            } label: {
                Label(String(localized: "Video", table: "Compress"), systemImage: "film")
            }
            .fixedSize()
            .help(String(localized: "Video preset", table: "Compress"))

            Button {
                editsImages.toggle()
            } label: {
                Label {
                    Text(verbatim: "HEIC \(model.settings.imageQuality.formatted(.percent.precision(.fractionLength(0))))")
                } icon: {
                    Image(systemName: "photo")
                }
            }
            .help(String(localized: "Photo settings", table: "Compress"))
            .popover(isPresented: $editsImages, arrowEdge: .bottom) {
                CompressImageSettings(settings: $model.settings)
            }
        }
        .disabled(model.isRunning)
    }
}

private struct CompressImageSettings: View {
    @Binding var settings: CompressSettings
    private static let sizes = [4096, 3072, 2048, 1024]

    var body: some View {
        Form {
            LabeledContent(String(localized: "Quality", table: "Compress")) {
                HStack {
                    Slider(value: $settings.imageQuality, in: 0.5...0.95, step: 0.05)
                        .frame(width: 160)
                    Text(settings.imageQuality.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            Picker(String(localized: "Maximum size", table: "Compress"), selection: $settings.imageMaxPixelSize) {
                Text("Original", tableName: "Compress").tag(Int?.none)
                ForEach(Self.sizes, id: \.self) { size in
                    Text(verbatim: "\(size) px").tag(Int?.some(size))
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

private struct CompressActionBar: View {
    @ObservedObject var model: CompressRoomModel

    var body: some View {
        HStack(spacing: 14) {
            Toggle(isOn: $model.replaceOriginals) {
                Text("Replace originals", tableName: "Compress")
            }
            .disabled(model.isRunning)
            .help(String(localized: "Moves each original to the Trash once its compressed copy is verified.", table: "Compress"))
            Spacer()
            if model.isRunning {
                ProgressView(value: model.overallProgress)
                    .frame(width: 180)
                Button(String(localized: "Cancel", table: "Compress")) { model.cancel() }
                    .controlSize(.large)
            } else {
                if model.items.contains(where: { !$0.canStart && !$0.isBusy }) {
                    Button(String(localized: "Clear Finished", table: "Compress")) { model.clearFinished() }
                        .controlSize(.large)
                }
                Button {
                    model.compressSelected()
                } label: {
                    if model.selectedCount == 0 {
                        Text("Compress", tableName: "Compress")
                    } else {
                        Text("Compress \(model.selectedCount) files", tableName: "Compress")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(VracRoom.compress.tint)
                .controlSize(.large)
                .disabled(model.selectedCount == 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct CompressItemRow: View {
    let item: CompressRoomModel.Item
    let estimate: Int64?
    @ObservedObject var model: CompressRoomModel

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { item.isSelected }, set: { model.setSelected(item.id, $0) })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!item.canStart || model.isRunning)

            CompressThumbnail(url: item.url, isVideo: item.info.kind == .video)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)

            Spacer(minLength: 12)
            sizes
            status
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button(String(localized: "Reveal in Finder", table: "Rooms"), systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([shownURL])
            }
            Button(String(localized: "Remove from List", table: "Compress"), systemImage: "minus.circle") {
                model.remove(item.id)
            }
            .disabled(item.isBusy)
        }
    }

    private var shownURL: URL {
        if case .done(let result) = item.status { result.output } else { item.url }
    }

    private var details: String {
        let info = item.info
        var parts = ["\(info.width) × \(info.height)"]
        if info.kind == .video {
            parts.append(Duration.seconds(info.duration).formatted(.time(pattern: info.duration >= 3600 ? .hourMinuteSecond : .minuteSecond)))
        }
        parts.append(codecName)
        parts.append((item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        return parts.joined(separator: " · ")
    }

    private var codecName: String {
        if case .done = item.status { return item.info.kind == .video ? "HEVC" : "HEIC" }
        let codec = item.info.codec
        switch codec {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "mp4v": return "MPEG-4"
        case _ where codec.hasPrefix("ap"): return "ProRes"
        default: return UTType(codec)?.preferredFilenameExtension?.uppercased() ?? codec
        }
    }

    @ViewBuilder
    private var sizes: some View {
        let original = RadixFormatters.size(item.info.bytes)
        VStack(alignment: .trailing, spacing: 2) {
            switch item.status {
            case .done(let result):
                Text(verbatim: "\(RadixFormatters.size(result.originalBytes)) → \(RadixFormatters.size(result.outputBytes))")
                gain(result.outputBytes, of: result.originalBytes)
            case .alreadyOptimized:
                Text(verbatim: original)
            default:
                if let estimate {
                    Text(verbatim: "\(original) → ~\(RadixFormatters.size(estimate))")
                    if CompressRules.isWorthKeeping(originalBytes: item.info.bytes, outputBytes: estimate) {
                        gain(estimate, of: item.info.bytes)
                    } else {
                        Text("Small gain", tableName: "Compress").foregroundStyle(.secondary)
                    }
                } else {
                    Text(verbatim: original)
                    Text("Estimating…", tableName: "Compress").foregroundStyle(.tertiary)
                }
            }
        }
        .font(.callout)
        .monospacedDigit()
    }

    private func gain(_ output: Int64, of original: Int64) -> some View {
        let fraction = original > 0 ? Double(original - output) / Double(original) : 0
        return Text(verbatim: "−\(fraction.formatted(.percent.precision(.fractionLength(0))))")
            .fontWeight(.semibold)
            .foregroundStyle(VracRoom.compress.tint)
    }

    @ViewBuilder
    private var status: some View {
        switch item.status {
        case .ready:
            EmptyView()
        case .queued:
            Text("Waiting", tableName: "Compress").foregroundStyle(.secondary)
        case .working(let progress):
            if let progress {
                ProgressView(value: progress).frame(width: 110)
            } else {
                ProgressView().controlSize(.small)
            }
        case .done(let result):
            HStack(spacing: 5) {
                Image(systemName: result.trashFailure == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.trashFailure == nil ? Color.green : Color.orange)
                if result.replacedOriginal {
                    Text("Replaced", tableName: "Compress")
                } else {
                    Text("Done", tableName: "Compress")
                }
            }
            .help(doneHelp(result))
        case .alreadyOptimized:
            Text("Already optimized", tableName: "Compress").foregroundStyle(.secondary)
        case .failed(let reason):
            Label(String(localized: "Failed", table: "Compress"), systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .help(reason)
        }
    }

    private func doneHelp(_ result: CompressResult) -> String {
        if let failure = result.trashFailure {
            return String(localized: "Original kept: \(failure)", table: "Compress")
        }
        return result.output.lastPathComponent
    }
}

private struct CompressThumbnail: View {
    let url: URL
    let isVideo: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: isVideo ? "film" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
        }
        .accessibilityHidden(true)
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: 128, height: 88), scale: 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}

private extension CompressVideoPreset {
    var title: Text {
        switch self {
        case .highestQuality: Text("HEVC Highest Quality", tableName: "Compress")
        case .hd1080: Text(verbatim: "HEVC 1080p")
        case .uhd4K: Text(verbatim: "HEVC 4K")
        }
    }
}
