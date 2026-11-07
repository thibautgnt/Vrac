import SwiftUI

struct OverviewRoomView: View {
    @ObservedObject private var model = OverviewRoomModel.shared
    @ObservedObject private var cleanup = CleanupRoomModel.shared
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.vracNavigator) private var navigator

    private static let reclaimColor = VracRoom.cleanup.tint
    private static let homeURL = URL(fileURLWithPath: NSHomeDirectory())

    var body: some View {
        RoomPage(room: .overview) {
            HStack(spacing: 10) {
                if model.isMeasuring {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }
                Button {
                    model.refresh()
                } label: {
                    Label(String(localized: "Refresh", table: "Overview"), systemImage: "arrow.clockwise")
                }
            }
        } content: {
            if let volume = model.volume {
                diskCard(volume)
                reclaimableCard
                breakdownCard(volume)
            } else {
                RoomEmptyState(
                    title: String(localized: "Startup disk unavailable", table: "Overview"),
                    message: String(localized: "macOS did not report the capacity of the startup disk.", table: "Overview"),
                    systemImage: "internaldrive",
                    actionTitle: String(localized: "Refresh", table: "Overview"),
                    action: model.refresh
                )
            }
        }
        .task {
            model.loadIfNeeded()
            cleanup.scanIfNeeded()
        }
    }


    private var reclaimableByCategory: [OverviewCategory: Int64] {
        guard !model.jobs.isEmpty else { return [:] }
        var bytes: [OverviewCategory: Int64] = [:]
        for item in cleanup.selectedItems {
            if let category = OverviewAccounting.category(of: item.url, in: model.jobs) {
                bytes[category, default: 0] += item.bytes
            }
        }
        return bytes
    }

    private func breakdown(_ volume: VolumeSnapshot) -> (kept: [OverviewCategory: Int64], reclaimable: Int64) {
        OverviewAccounting.breakdown(measured: model.measured, used: volume.used, reclaimable: reclaimableByCategory)
    }

    private func segments(_ volume: VolumeSnapshot) -> [StorageSegment] {
        let (kept, reclaimable) = breakdown(volume)
        var segments = OverviewCategory.allCases.map { category in
            StorageSegment(
                id: category.rawValue,
                label: category == .system && model.isMeasuring
                    ? String(localized: "Not measured yet", table: "Overview")
                    : category.title,
                bytes: kept[category] ?? 0,
                color: category == .system && model.isMeasuring ? Color.primary.opacity(0.16) : category.tone
            )
        }
        segments.append(StorageSegment(
            id: "reclaimable",
            label: String(localized: "Reclaimable", table: "Overview"),
            bytes: reclaimable,
            color: Self.reclaimColor
        ))
        return segments
    }


    private func diskCard(_ volume: VolumeSnapshot) -> some View {
        RoomCard(padding: 24) {
            HStack(alignment: .center, spacing: 36) {
                StorageRing(segments: segments(volume), total: volume.total) {
                    VStack(spacing: 2) {
                        Text(RadixFormatters.size(volume.available))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("available space", tableName: "Overview")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 196, height: 196)

                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label {
                            Text(verbatim: volume.name)
                        } icon: {
                            Image(systemName: "internaldrive.fill")
                                .foregroundStyle(.secondary)
                        }
                        .font(.title2.weight(.semibold))
                        Text("\(RadixFormatters.size(volume.used)) used of \(RadixFormatters.size(volume.total))", tableName: "Overview")
                            .foregroundStyle(.secondary)
                    }
                    HStack(alignment: .top, spacing: 32) {
                        RoomStat(value: RadixFormatters.size(volume.total), caption: String(localized: "Capacity", table: "Overview"))
                        RoomStat(value: RadixFormatters.size(volume.used), caption: String(localized: "Used", table: "Overview"))
                        RoomStat(value: RadixFormatters.size(volume.available), caption: String(localized: "Available", table: "Overview"))
                    }
                    if volume.purgeable > 0 {
                        Text("macOS can free \(RadixFormatters.size(volume.purgeable)) more on its own when space runs low (purgeable space).", tableName: "Overview")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }


    private var reclaimableCard: some View {
        RoomCard(padding: 18) {
            HStack(spacing: 16) {
                RoomIcon(room: .cleanup, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reclaimable", tableName: "Overview")
                        .font(.headline)
                    Text("Caches, logs, build files and installers selected in Cleanup.", tableName: "Overview")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if !cleanup.items.isEmpty {
                    if cleanup.phase != .done {
                        ProgressView().controlSize(.small)
                    }
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(RadixFormatters.size(cleanup.selectedBytes))
                            .font(.system(.title2, design: .rounded).weight(.semibold))
                            .foregroundStyle(Self.reclaimColor)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        let toReview = cleanup.totalBytes - cleanup.selectedBytes
                        if toReview > 0 {
                            Text("\(RadixFormatters.size(toReview)) more to review", tableName: "Overview")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if cleanup.phase != .done {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching", tableName: "Overview")
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    navigator.openRoom(.cleanup)
                } label: {
                    Text("Review", tableName: "Overview")
                        .frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .tint(Self.reclaimColor)
                .controlSize(.large)
            }
        }
    }


    private func breakdownCard(_ volume: VolumeSnapshot) -> some View {
        let (kept, _) = breakdown(volume)
        let reclaimable = reclaimableByCategory
        return RoomCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("What takes up space", tableName: "Overview")
                        .font(.headline)
                    Spacer()
                    Button {
                        navigator.explore(URL(fileURLWithPath: "/"))
                    } label: {
                        Label(String(localized: "Explore Whole Disk", table: "Overview"), systemImage: "chart.pie")
                    }
                }
                .padding([.horizontal, .top], 18)

                StorageSegmentBar(segments: segments(volume), total: volume.used, height: 14, showsLegend: false)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                    .animation(.smooth, value: segments(volume))

                ForEach(OverviewCategory.allCases, id: \.self) { category in
                    Divider().padding(.leading, 18)
                    CategoryRow(
                        category: category,
                        bytes: category == .system ? kept[.system] ?? 0 : model.measured[category] ?? 0,
                        reclaimable: reclaimable[category] ?? 0,
                        isPending: category == .system ? model.isMeasuring : (model.pendingJobs[category] ?? 0) > 0,
                        explore: { navigator.explore(category.exploreURL(home: Self.homeURL)) }
                    )
                }

                if !model.isMeasuring, model.unreadableFolders > 0, appModel.fullDiskAccessStatus != .granted {
                    Divider()
                    HStack(spacing: 10) {
                        Image(systemName: "lock")
                            .foregroundStyle(.secondary)
                        Text("Some folders could not be read and are counted in System and other. Allow Full Disk Access for a finer breakdown.", tableName: "Overview")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(String(localized: "Open Settings", table: "Overview")) {
                            appModel.prepareAndOpenFullDiskAccessSettings()
                        }
                        .controlSize(.small)
                    }
                    .padding(18)
                }
            }
            .padding(.bottom, 6)
        }
    }
}

private struct CategoryRow: View {
    let category: OverviewCategory
    let bytes: Int64
    let reclaimable: Int64
    let isPending: Bool
    let explore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(category.tone)
                .frame(width: 12, height: 12)
            Image(systemName: category.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(category.title)
                Text(category.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if reclaimable > 0 {
                Text("\(RadixFormatters.size(reclaimable)) reclaimable", tableName: "Overview")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(VracRoom.cleanup.tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(VracRoom.cleanup.tint.opacity(0.12), in: Capsule())
            }
            HStack(spacing: 6) {
                if isPending {
                    ProgressView().controlSize(.mini)
                }
                if category != .system || !isPending {
                    Text(bytes > 0 || isPending ? RadixFormatters.size(bytes) : "–")
                        .monospacedDigit()
                        .foregroundStyle(isPending ? .secondary : .primary)
                        .contentTransition(.numericText())
                }
            }
            .frame(minWidth: 72, alignment: .trailing)
            Button(String(localized: "Explore", table: "Overview"), action: explore)
                .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }
}

/// Donut drawn from the same segments as the bar; the empty track is the free space.
private struct StorageRing<Center: View>: View {
    let segments: [StorageSegment]
    let total: Int64
    @ViewBuilder var center: () -> Center

    private let lineWidth: CGFloat = 22

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.05), lineWidth: lineWidth)
            ForEach(arcs, id: \.segment.id) { arc in
                Circle()
                    .trim(from: arc.start, to: arc.end)
                    .stroke(arc.segment.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            center()
        }
        .padding(lineWidth / 2)
        .animation(.smooth(duration: 0.6), value: segments)
        .accessibilityElement(children: .combine)
    }

    private var arcs: [(segment: StorageSegment, start: CGFloat, end: CGFloat)] {
        guard total > 0 else { return [] }
        let gap: CGFloat = 0.003
        var start: CGFloat = 0
        return segments.filter { $0.bytes > 0 }.map { segment in
            let length = CGFloat(Double(segment.bytes) / Double(total))
            defer { start += length }
            return (segment, start, max(start, start + length - gap))
        }
    }
}

extension OverviewCategory {
    var title: String {
        switch self {
        case .applications: String(localized: "Applications", table: "Overview")
        case .documents: String(localized: "Documents", table: "Overview")
        case .downloads: String(localized: "Downloads", table: "Overview")
        case .media: String(localized: "Photos and media", table: "Overview")
        case .iCloud: String(localized: "iCloud Drive", table: "Overview")
        case .developer: String(localized: "Developer", table: "Overview")
        case .mail: String(localized: "Mail and Messages", table: "Overview")
        case .otherUser: String(localized: "Other user data", table: "Overview")
        case .system: String(localized: "System and other", table: "Overview")
        }
    }

    var detail: String {
        switch self {
        case .applications: String(localized: "Applications folders", table: "Overview")
        case .documents: String(localized: "Documents and Desktop", table: "Overview")
        case .downloads: String(localized: "Downloads folder", table: "Overview")
        case .media: String(localized: "Pictures, Movies and Music", table: "Overview")
        case .iCloud: String(localized: "Files kept on this Mac", table: "Overview")
        case .developer: String(localized: "Xcode, simulators and projects", table: "Overview")
        case .mail: String(localized: "Mailboxes, attachments and conversations", table: "Overview")
        case .otherUser: String(localized: "Library, caches and the rest of your home folder", table: "Overview")
        case .system: String(localized: "macOS, snapshots and other users", table: "Overview")
        }
    }

    var systemImage: String {
        switch self {
        case .applications: "square.grid.2x2"
        case .documents: "doc"
        case .downloads: "arrow.down.circle"
        case .media: "photo.on.rectangle"
        case .iCloud: "icloud"
        case .developer: "hammer"
        case .mail: "envelope"
        case .otherUser: "person.crop.circle"
        case .system: "gearshape"
        }
    }

    /// Gray tones that alternate so neighbours stay distinct; color is kept for what can be reclaimed.
    var tone: Color {
        let opacity: Double = switch self {
        case .applications: 0.78
        case .documents: 0.64
        case .downloads: 0.52
        case .media: 0.42
        case .iCloud: 0.34
        case .developer: 0.58
        case .mail: 0.27
        case .otherUser: 0.46
        case .system: 0.22
        }
        return Color.primary.opacity(opacity)
    }

    func exploreURL(home: URL) -> URL {
        switch self {
        case .applications: URL(fileURLWithPath: "/Applications")
        case .documents: home.appendingPathComponent("Documents")
        case .downloads: home.appendingPathComponent("Downloads")
        case .media: home.appendingPathComponent("Pictures")
        case .iCloud: home.appendingPathComponent("Library/Mobile Documents")
        case .developer: home.appendingPathComponent("Library/Developer")
        case .mail: home.appendingPathComponent("Library/Mail")
        case .otherUser: home
        case .system: URL(fileURLWithPath: "/")
        }
    }
}
