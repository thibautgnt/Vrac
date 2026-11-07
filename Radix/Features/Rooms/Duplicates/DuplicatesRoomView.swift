import AppKit
import QuickLookThumbnailing
import SwiftUI

struct DuplicatesRoomView: View {
    @ObservedObject private var model = DuplicatesRoomModel.shared
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        RoomPage(room: .duplicates) {
            if model.state == .results {
                Button(String(localized: "New Scan", table: "Duplicates"), systemImage: "arrow.counterclockwise", action: model.startOver)
            }
        } content: {
            switch model.state {
            case .idle: setup
            case .scanning: scanning
            case .results: results
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.state == .results, !model.groups.isEmpty {
                TrashSelectionBar(
                    itemCount: model.selection.selectedCount(in: model.groups),
                    bytes: model.selection.reclaimableBytes(in: model.groups),
                    isWorking: model.isTrashing,
                    moveToTrash: model.moveSelectionToTrash
                )
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.state == .idle else { return false }
            model.add(urls)
            return true
        }
        #if DEBUG
        .task { model.startDebugScanIfRequested() }
        #endif
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 20) {
            RoomCard {
                VStack(alignment: .leading, spacing: 14) {
                    Explanation(
                        systemImage: "equal.square",
                        title: String(localized: "Byte for byte", table: "Duplicates"),
                        message: String(localized: "Only files whose content is exactly the same are reported, whatever their name.", table: "Duplicates")
                    )
                    Explanation(
                        systemImage: "lock",
                        title: String(localized: "On this Mac", table: "Duplicates"),
                        message: String(localized: "Files are read locally. Nothing is uploaded, nothing is changed during the scan.", table: "Duplicates")
                    )
                    Explanation(
                        systemImage: "checkmark.circle",
                        title: String(localized: "One copy always stays", table: "Duplicates"),
                        message: String(localized: "Vrac suggests which copies to move to the Trash, never all of them. You review everything first.", table: "Duplicates")
                    )
                }
            }

            RoomCard {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 14) {
                    GridRow {
                        Text("Folders", tableName: "Duplicates")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.roots, id: \.self) { root in
                                HStack(spacing: 8) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: root.path))
                                        .resizable()
                                        .frame(width: 18, height: 18)
                                        .accessibilityHidden(true)
                                    Text(verbatim: (root.path as NSString).abbreviatingWithTildeInPath)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if model.roots.count > 1 {
                                        Button(String(localized: "Remove", table: "Duplicates"), systemImage: "xmark.circle.fill") {
                                            model.remove(root)
                                        }
                                        .labelStyle(.iconOnly)
                                        .buttonStyle(.borderless)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            HStack(spacing: 10) {
                                Button(String(localized: "Add Folders…", table: "Duplicates"), action: model.chooseFolders)
                                Text("or drop folders here", tableName: "Duplicates")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    GridRow {
                        Text("Minimum size", tableName: "Duplicates")
                            .foregroundStyle(.secondary)
                        Picker(String(localized: "Minimum size", table: "Duplicates"), selection: $model.minimumSize) {
                            ForEach(DuplicatesRoomModel.minimumSizes, id: \.self) { size in
                                Text(verbatim: RadixFormatters.size(size)).tag(size)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow {
                        Text("Library", tableName: "Duplicates")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(String(localized: "Include ~/Library", table: "Duplicates"), isOn: $model.includesLibrary)
                            Text("App data lives there; duplicates inside it are often needed by the app that made them.", tableName: "Duplicates")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button(action: model.start) {
                    Label(String(localized: "Find Duplicates", table: "Duplicates"), systemImage: "magnifyingglass")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(VracRoom.duplicates.tint)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var scanning: some View {
        RoomCard(padding: 22) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(phaseTitle)
                        .font(.headline)
                    Spacer()
                    Button(String(localized: "Stop", table: "Duplicates"), action: model.cancel)
                }
                if model.progress.phase == .hashing, model.progress.bytesToHash > 0 {
                    ProgressView(value: Double(model.progress.bytesHashed), total: Double(model.progress.bytesToHash))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                HStack(alignment: .top, spacing: 36) {
                    RoomStat(
                        value: model.progress.filesSeen.formatted(),
                        caption: String(localized: "Files examined", table: "Duplicates")
                    )
                    RoomStat(
                        value: model.progress.candidates.formatted(),
                        caption: String(localized: "Same size as another", table: "Duplicates")
                    )
                    RoomStat(
                        value: RadixFormatters.size(model.progress.bytesHashed),
                        caption: String(localized: "Read in full", table: "Duplicates")
                    )
                }
            }
        }
    }

    private var phaseTitle: String {
        switch model.progress.phase {
        case .listing: String(localized: "Listing files…", table: "Duplicates")
        case .sampling: String(localized: "Comparing the start and end of files…", table: "Duplicates")
        case .hashing: String(localized: "Reading files in full…", table: "Duplicates")
        case .confirming: String(localized: "Checking byte for byte…", table: "Duplicates")
        }
    }

    @ViewBuilder
    private var results: some View {
        if let report = model.trashReport {
            TrashReportBanner(report: report)
        }
        if model.unreadableCount > 0 {
            RoomCard(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.unreadableCount) items could not be read", tableName: "Duplicates")
                            .font(.headline)
                        Text("Give Vrac Full Disk Access to compare files in protected folders too.", tableName: "Duplicates")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(String(localized: "Open Settings", table: "Duplicates"), action: appModel.prepareAndOpenFullDiskAccessSettings)
                }
            }
        }
        if model.groups.isEmpty {
            RoomEmptyState(
                title: String(localized: "No Duplicates", table: "Duplicates"),
                message: String(localized: "No identical files of \(RadixFormatters.size(model.minimumSize)) or more among the \(model.filesSeen) files examined.", table: "Duplicates"),
                systemImage: "checkmark.seal",
                actionTitle: String(localized: "New Scan", table: "Duplicates"),
                action: model.startOver
            )
        } else {
            summary
            filters
            let groups = model.visibleGroups
            if groups.isEmpty {
                Text("No group matches these filters.", tableName: "Duplicates")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            LazyVStack(spacing: 12) {
                ForEach(groups) { group in
                    DuplicateGroupCard(group: group, model: model)
                }
            }
        }
    }

    private var summary: some View {
        RoomCard {
            HStack(alignment: .top, spacing: 40) {
                RoomStat(
                    value: RadixFormatters.size(model.reclaimableBytes),
                    caption: String(localized: "Reclaimable", table: "Duplicates"),
                    tint: VracRoom.duplicates.tint
                )
                RoomStat(value: model.groups.count.formatted(), caption: String(localized: "Groups", table: "Duplicates"))
                RoomStat(value: model.fileCount.formatted(), caption: String(localized: "Files", table: "Duplicates"))
                Spacer()
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            TextField(String(localized: "Search by name", table: "Duplicates"), text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
            Picker(String(localized: "Kind", table: "Duplicates"), selection: $model.kind) {
                Text("All Kinds", tableName: "Duplicates").tag(DuplicateKind?.none)
                Divider()
                ForEach(DuplicateKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(Optional(kind))
                }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            Picker(String(localized: "Keep", table: "Duplicates"), selection: $model.rule) {
                ForEach(DuplicateKeepRule.allCases, id: \.self) { rule in
                    Text(rule.title).tag(rule)
                }
            }
            .fixedSize()
            .help(String(localized: "Which copy of each group stays where it is. The others are selected for the Trash.", table: "Duplicates"))
        }
    }
}

private struct Explanation: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(VracRoom.duplicates.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message).foregroundStyle(.secondary)
            }
        }
    }
}

private struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    @ObservedObject var model: DuplicatesRoomModel

    var body: some View {
        RoomCard(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    FileThumbnail(url: group.files[0].url)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: group.name)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(verbatim: "\(String(localized: "\(group.files.count) copies", table: "Duplicates")) · \(RadixFormatters.size(group.size))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if group.reclaimableBytes > 0 {
                        Text(verbatim: RadixFormatters.size(group.reclaimableBytes))
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(VracRoom.duplicates.tint)
                    } else {
                        Text("Already share storage", tableName: "Duplicates")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .help(String(localized: "These copies are APFS clones: they use the space of a single file, so trashing them frees nothing.", table: "Duplicates"))
                    }
                }
                .padding(14)
                ForEach(group.files) { file in
                    Divider().padding(.leading, 14)
                    CopyRow(file: file, group: group, model: model)
                }
            }
        }
    }
}

private struct CopyRow: View {
    let file: DuplicateFile
    let group: DuplicateGroup
    @ObservedObject var model: DuplicatesRoomModel

    var body: some View {
        let selected = model.isSelected(file)
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { selected }, set: { _ in model.toggle(file, in: group) })) {
                Text(verbatim: file.url.lastPathComponent)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!model.canSelect(file, in: group))
            .help(model.canSelect(file, in: group) ? "" : String(localized: "At least one copy is always kept.", table: "Duplicates"))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: (file.url.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(selected ? .primary : .secondary)
                Text("Created \(RadixFormatters.date(file.created ?? file.modified)) · modified \(RadixFormatters.date(file.modified))", tableName: "Duplicates")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if group.sharesStorage(file) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Shares its storage with another copy: trashing it alone frees nothing.", table: "Duplicates"))
                    .accessibilityLabel(String(localized: "Shares storage", table: "Duplicates"))
            }
            if !selected {
                Text("Kept", tableName: "Duplicates")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            Button(String(localized: "Reveal in Finder", table: "Duplicates"), systemImage: "arrow.right.circle") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(String(localized: "Reveal in Finder", table: "Duplicates"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct FileThumbnail: View {
    let url: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .scaledToFit()
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
            .task(id: url) {
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 40, height: 40), scale: 2, representationTypes: .thumbnail)
                thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            }
    }
}

private struct TrashReportBanner: View {
    let report: DuplicatesRoomModel.TrashReport

    var body: some View {
        RoomCard(padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: report.failures.isEmpty && report.skipped.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(report.failures.isEmpty && report.skipped.isEmpty ? .green : .orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(RadixFormatters.size(report.freedBytes)) freed", tableName: "Duplicates")
                        .font(.headline)
                    Text("\(report.trashedCount) files moved to the Trash", tableName: "Duplicates")
                        .foregroundStyle(.secondary)
                    if !report.skipped.isEmpty {
                        Text("\(report.skipped.count) files changed since the scan and were left in place.", tableName: "Duplicates")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(report.failures, id: \.self) { failure in
                        Text(verbatim: "\(failure.url.lastPathComponent) : \(failure.reason)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private extension DuplicateKind {
    var title: String {
        switch self {
        case .images: String(localized: "Images", table: "Duplicates")
        case .videos: String(localized: "Videos", table: "Duplicates")
        case .audio: String(localized: "Audio", table: "Duplicates")
        case .documents: String(localized: "Documents", table: "Duplicates")
        case .archives: String(localized: "Archives", table: "Duplicates")
        case .other: String(localized: "Other", table: "Duplicates")
        }
    }
}

private extension DuplicateKeepRule {
    var title: String {
        switch self {
        case .oldest: String(localized: "The oldest", table: "Duplicates")
        case .newest: String(localized: "The newest", table: "Duplicates")
        case .shortestPath: String(localized: "The shortest path", table: "Duplicates")
        case .outsideDownloads: String(localized: "The one outside Downloads", table: "Duplicates")
        }
    }
}
