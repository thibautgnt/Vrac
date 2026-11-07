import AppKit
import SwiftUI

/// Page frame shared by every room: header with the room icon, then content.
/// Pass `scrolls: false` when the content brings its own scrolling (List, Table).
struct RoomPage<Accessory: View, Content: View>: View {
    let room: VracRoom
    var scrolls = true
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        if scrolls {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    RoomHeader(room: room, accessory: accessory)
                    content()
                }
                .padding(28)
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                RoomHeader(room: room, accessory: accessory)
                    .padding([.horizontal, .top], 28)
                content()
            }
        }
    }
}

extension RoomPage where Accessory == EmptyView {
    init(room: VracRoom, scrolls: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.init(room: room, scrolls: scrolls, accessory: { EmptyView() }, content: content)
    }
}

struct RoomHeader<Accessory: View>: View {
    let room: VracRoom
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            RoomIcon(room: room, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(room.title)
                    .font(.title.weight(.semibold))
                Text(room.subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            accessory()
        }
    }
}

struct RoomIcon: View {
    let room: VracRoom
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(room.tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: room.systemImage)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// Rounded panel used to group content inside a room.
struct RoomCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
            }
    }
}

/// A big number with a caption, e.g. "12,4 GB — reclaimable".
struct RoomStat: View {
    let value: String
    let caption: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(caption)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct StorageSegment: Identifiable, Hashable {
    let id: String
    let label: String
    let bytes: Int64
    let color: Color
}

/// Horizontal bar split by category, like System Settings > Storage.
/// Convention: what is kept is drawn in gray tones, what can be cleaned in color.
struct StorageSegmentBar: View {
    let segments: [StorageSegment]
    let total: Int64
    var height: CGFloat = 24
    var showsLegend = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(visibleSegments) { segment in
                        Rectangle()
                            .fill(segment.color.gradient)
                            .frame(width: max(3, proxy.size.width * fraction(segment)))
                            .help(Text(verbatim: "\(segment.label) · \(RadixFormatters.size(segment.bytes))"))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)

            if showsLegend {
                FlowLegend(segments: visibleSegments)
            }
        }
    }

    private var visibleSegments: [StorageSegment] {
        segments.filter { $0.bytes > 0 }
    }

    private func fraction(_ segment: StorageSegment) -> CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(Double(segment.bytes) / Double(total))
    }

    private var accessibilitySummary: String {
        visibleSegments.map { "\($0.label) \(RadixFormatters.size($0.bytes))" }.joined(separator: ", ")
    }
}

private struct FlowLegend: View {
    let segments: [StorageSegment]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(segments) { segment in
                HStack(spacing: 6) {
                    Circle().fill(segment.color).frame(width: 8, height: 8)
                    Text(segment.label)
                    Text(RadixFormatters.size(segment.bytes))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.callout)
                .lineLimit(1)
            }
        }
    }
}

/// Bottom bar showing the current selection and the single "Move to Trash" action of a room.
/// Rooms never delete directly: everything goes through this confirmation, then `RoomTrash`.
struct TrashSelectionBar: View {
    let itemCount: Int
    let bytes: Int64
    var isWorking = false
    let moveToTrash: () -> Void

    @State private var confirms = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(itemCount) items selected", tableName: "Rooms")
                    .font(.headline)
                Text(RadixFormatters.size(bytes))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if isWorking {
                ProgressView().controlSize(.small)
            }
            Button(role: .destructive) {
                confirms = true
            } label: {
                Label(String(localized: "Move to Trash", table: "Rooms"), systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(itemCount == 0 || isWorking)
            .confirmationDialog(
                String(localized: "Move \(itemCount) items to the Trash?", table: "Rooms"),
                isPresented: $confirms
            ) {
                Button(String(localized: "Move to Trash", table: "Rooms"), role: .destructive, action: moveToTrash)
            } message: {
                Text("You can put them back from the Trash until it is emptied.", tableName: "Rooms")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct RoomEmptyState: View {
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

/// Row with Finder icon, name, path and size; reused by room lists.
struct RoomFileRow: View {
    let url: URL
    let bytes: Int64
    var detail: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail ?? (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(RadixFormatters.size(bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button(String(localized: "Reveal in Finder", table: "Rooms"), systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

/// Placeholder until a room is built.
struct RoomComingSoon: View {
    let room: VracRoom

    var body: some View {
        RoomPage(room: room) {
            RoomEmptyState(
                title: room.title,
                message: room.subtitle,
                systemImage: room.systemImage
            )
        }
    }
}
