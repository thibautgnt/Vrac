import AppKit
import SwiftUI

struct CleanupRoomView: View {
    @ObservedObject private var model = CleanupRoomModel.shared
    @EnvironmentObject private var appModel: AppModel
    @State private var expanded: Set<CleanupCategory> = []

    var body: some View {
        RoomPage(room: .cleanup) {
            Button {
                model.lastTrash = nil
                model.rescan()
            } label: {
                Label(String(localized: "Rescan", table: "Cleanup"), systemImage: "arrow.clockwise")
            }
            .disabled(model.isTrashing)
        } content: {
            if let result = model.lastTrash {
                CleanupTrashReport(result: result) { model.lastTrash = nil }
            }
            if model.phase != .done {
                if model.items.isEmpty { scanningCard } else { scanningStrip }
            } else if model.items.isEmpty {
                RoomEmptyState(
                    title: String(localized: "Nothing to clean up", table: "Cleanup"),
                    message: String(localized: "No caches, logs or leftovers worth removing were found.", table: "Cleanup"),
                    systemImage: "checkmark.seal",
                    actionTitle: String(localized: "Rescan", table: "Cleanup"),
                    action: model.rescan
                )
            }
            if !model.items.isEmpty {
                summary
                ForEach(CleanupCategory.allCases, id: \.self) { category in
                    let items = model.items(in: category)
                    if !items.isEmpty {
                        CleanupCategoryCard(
                            category: category,
                            items: items,
                            model: model,
                            isExpanded: Binding(
                                get: { expanded.contains(category) },
                                set: { if $0 { expanded.insert(category) } else { expanded.remove(category) } }
                            )
                        )
                    }
                }
            }
            if model.phase == .done, model.unreadableLocations > 0, appModel.fullDiskAccessStatus != .granted {
                fullDiskAccessNotice
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.items.isEmpty {
                TrashSelectionBar(
                    itemCount: model.selection.count,
                    bytes: model.selectedBytes,
                    isWorking: model.isTrashing,
                    moveToTrash: model.moveSelectionToTrash
                )
            }
        }
        .task { model.scanIfNeeded() }
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 36) {
            RoomStat(
                value: RadixFormatters.size(model.totalBytes),
                caption: String(localized: "can be freed", table: "Cleanup"),
                tint: VracRoom.cleanup.tint
            )
            RoomStat(
                value: RadixFormatters.size(model.selectedBytes),
                caption: String(localized: "selected", table: "Cleanup")
            )
            Spacer()
            Text("Everything goes to the Trash, nothing is deleted for good.", tableName: "Cleanup")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 4)
    }

    private var scanningCard: some View {
        RoomCard(padding: 28) {
            VStack(spacing: 14) {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(VracRoom.cleanup.tint)
                    .frame(maxWidth: 360)
                Text("Looking for space you can safely reclaim", tableName: "Cleanup")
                    .font(.headline)
                Text("Caches, logs, build files, installers and old downloads.", tableName: "Cleanup")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        }
    }

    private var scanningStrip: some View {
        HStack(spacing: 12) {
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .tint(VracRoom.cleanup.tint)
                .frame(maxWidth: 220)
            Text("Still looking, more items may appear", tableName: "Cleanup")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var fullDiskAccessNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock")
                .foregroundStyle(.secondary)
            Text("\(model.unreadableLocations) locations could not be read. Allow Full Disk Access to include them.", tableName: "Cleanup")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "Open Settings", table: "Cleanup")) {
                appModel.prepareAndOpenFullDiskAccessSettings()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 4)
    }
}

private struct CleanupCategoryCard: View {
    let category: CleanupCategory
    let items: [CleanupItem]
    @ObservedObject var model: CleanupRoomModel
    @Binding var isExpanded: Bool

    var body: some View {
        RoomCard(padding: 0) {
            VStack(spacing: 0) {
                header
                    .padding(16)
                if isExpanded {
                    Divider()
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            CleanupItemRow(item: item, isSelected: model.binding(for: item))
                            if item.id != items.last?.id {
                                Divider().padding(.leading, 76)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Toggle(sources: items.map(model.binding(for:)), isOn: \.self) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(category.title)
            Image(systemName: category.systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(VracRoom.cleanup.tint)
                .frame(width: 36, height: 36)
                .background(VracRoom.cleanup.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(.headline)
                Text(category.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(RadixFormatters.size(items.reduce(0) { $0 + $1.bytes }))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text("\(selectedCount) of \(items.count) selected", tableName: "Cleanup")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button {
                withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(isExpanded
                ? String(localized: "Hide items", table: "Cleanup")
                : String(localized: "Show items", table: "Cleanup"))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
        }
    }

    private var selectedCount: Int {
        items.filter { model.selection.contains($0.url) }.count
    }
}

private struct CleanupItemRow: View {
    let item: CleanupItem
    @Binding var isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(item.title)
            RoomFileRow(url: item.url, bytes: item.bytes, detail: detail, title: item.title)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(String(localized: "Reveal in Finder", table: "Rooms"))
            .accessibilityLabel(String(localized: "Reveal in Finder", table: "Rooms"))
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .padding(.vertical, 7)
    }

    private var detail: String {
        let folder = (item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        if item.isAppRunning {
            return String(localized: "App is open, quit it to clear this cache", table: "Cleanup")
        }
        guard item.category.showsAge, let lastUsed = item.lastUsed else { return folder }
        let age = lastUsed.formatted(.relative(presentation: .named))
        return String(localized: "\(folder) · modified \(age)", table: "Cleanup")
    }
}

private struct CleanupTrashReport: View {
    let result: RoomTrashResult
    let dismiss: () -> Void

    var body: some View {
        RoomCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: result.trashedURLs.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(result.trashedURLs.isEmpty ? Color.orange : VracRoom.cleanup.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(RadixFormatters.size(result.freedBytes)) moved to the Trash", tableName: "Cleanup")
                            .font(.headline)
                        Text("Empty the Trash to get the space back.", tableName: "Cleanup")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "Dismiss", table: "Cleanup"))
                }
                if !result.failures.isEmpty {
                    Divider()
                    Text("\(result.failures.count) items could not be moved", tableName: "Cleanup")
                        .font(.subheadline.weight(.semibold))
                    ForEach(result.failures, id: \.url) { failure in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: (failure.url.path as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(verbatim: failure.reason)
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }
}

extension CleanupCategory {
    var title: String {
        switch self {
        case .appCaches: String(localized: "App caches", table: "Cleanup")
        case .logs: String(localized: "Logs and crash reports", table: "Cleanup")
        case .developer: String(localized: "Developer files", table: "Cleanup")
        case .installers: String(localized: "Installers", table: "Cleanup")
        case .oldDownloads: String(localized: "Old downloads", table: "Cleanup")
        case .mailAttachments: String(localized: "Mail attachments", table: "Cleanup")
        }
    }

    var summary: String {
        switch self {
        case .appCaches:
            String(localized: "Temporary files that apps rebuild on their own when needed.", table: "Cleanup")
        case .logs:
            String(localized: "Technical history of apps and macOS, mostly useful for troubleshooting.", table: "Cleanup")
        case .developer:
            String(localized: "Xcode build data, package manager caches and dependencies of idle projects. Archives and idle projects are left unselected.", table: "Cleanup")
        case .installers:
            String(localized: "Disk images and install packages in Downloads and on the Desktop. Those older than a week are selected.", table: "Cleanup")
        case .oldDownloads:
            String(localized: "Files in Downloads untouched for more than 90 days. Check them before removing anything.", table: "Cleanup")
        case .mailAttachments:
            String(localized: "Copies of attachments opened from Mail. They stay available in your messages.", table: "Cleanup")
        }
    }

    var systemImage: String {
        switch self {
        case .appCaches: "square.stack.3d.up"
        case .logs: "doc.text.magnifyingglass"
        case .developer: "hammer"
        case .installers: "shippingbox"
        case .oldDownloads: "arrow.down.circle"
        case .mailAttachments: "paperclip"
        }
    }

    var showsAge: Bool {
        switch self {
        case .developer, .installers, .oldDownloads: true
        case .appCaches, .logs, .mailAttachments: false
        }
    }
}
