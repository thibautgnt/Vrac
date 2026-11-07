import AppKit
import SwiftUI

struct AppDetailView: View {
    @ObservedObject var model: ApplicationsRoomModel
    let row: AppRow

    @State private var confirmsUninstall = false
    @State private var confirmsReset = false

    private var selectedData: [AppDataItem] { model.selectedData(of: row) }
    private var selectedBytes: Int64 { selectedData.reduce(0) { $0 + ($1.bytes ?? 0) } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    sizes
                    if let usage = model.usage {
                        running(usage)
                    }
                    files
                }
                .padding(20)
            }
            if !row.app.isSystemProtected {
                actions
            }
        }
        .task(id: row.id) { await model.monitor(row.app) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppIcon(url: row.app.url, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(verbatim: [row.app.version, row.source].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                if let bundleID = row.app.bundleID {
                    Text(verbatim: bundleID)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var sizes: some View {
        RoomCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    RoomStat(value: row.totalBytes.map(RadixFormatters.size) ?? "…", caption: String(localized: "Total", table: "Applications"))
                    Spacer()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([row.app.url])
                    } label: {
                        Label(String(localized: "Reveal in Finder", table: "Rooms"), systemImage: "folder")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(String(localized: "Reveal in Finder", table: "Rooms"))
                }
                StorageSegmentBar(
                    segments: [
                        StorageSegment(id: "app", label: String(localized: "Application", table: "Applications"), bytes: row.bundleBytes ?? 0, color: VracRoom.applications.tint),
                        StorageSegment(id: "data", label: String(localized: "Data", table: "Applications"), bytes: row.dataBytes ?? 0, color: .purple.opacity(0.55))
                    ],
                    total: row.totalBytes ?? 0,
                    height: 10
                )
                if row.app.isSystemProtected {
                    Label(String(localized: "This app is part of macOS and cannot be removed.", table: "Applications"), systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func running(_ usage: AppUsage) -> some View {
        RoomCard(padding: 14) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(String(localized: "Running", table: "Applications"), systemImage: "circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .labelStyle(DotLabelStyle())
                    HStack(spacing: 16) {
                        RoomStat(value: usage.cpuPercent.map { $0.formatted(.number.precision(.fractionLength(1))) + " %" } ?? "…", caption: String(localized: "CPU", table: "Applications"))
                        RoomStat(value: RadixFormatters.size(Int64(usage.memoryBytes)), caption: String(localized: "Memory", table: "Applications"))
                    }
                }
                Spacer()
                Button(String(localized: "Quit", table: "Applications")) {
                    model.quit(row.app)
                }
            }
        }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Associated files", tableName: "Applications")
                .font(.headline)
            if model.sharesBundleID(row) {
                Label(String(localized: "Another installed app uses the same identifier, so these files are not checked.", table: "Applications"), systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if row.data.isEmpty {
                Text("No associated files found.", tableName: "Applications")
                    .foregroundStyle(.secondary)
            } else {
                RoomCard(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(row.data) { item in
                            DataItemRow(
                                item: item,
                                isSelected: Binding(
                                    get: { !model.excludedData.contains(item.id) },
                                    set: { selected in
                                        if selected { model.excludedData.remove(item.id) } else { model.excludedData.insert(item.id) }
                                    }
                                ),
                                isEnabled: !row.app.isSystemProtected
                            )
                            if item.id != row.data.last?.id { Divider().padding(.leading, 34) }
                        }
                    }
                }
            }
        }
    }

    private var actions: some View {
        let isRunning = model.usage != nil
        return VStack(alignment: .leading, spacing: 8) {
            if isRunning {
                Text("Quit the app before removing it.", tableName: "Applications")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                confirmsUninstall = true
            } label: {
                HStack {
                    Text("Uninstall…", tableName: "Applications")
                    if model.isWorking {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(isRunning || model.isWorking)
            Button {
                confirmsReset = true
            } label: {
                Text("Delete Data Only…", tableName: "Applications")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(selectedData.isEmpty || isRunning || model.isWorking)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .confirmationDialog(
            String(localized: "Uninstall \(row.name)?", table: "Applications"),
            isPresented: $confirmsUninstall
        ) {
            Button(String(localized: "Move to Trash", table: "Rooms"), role: .destructive) {
                model.remove(row, uninstall: true)
            }
        } message: {
            Text("The app and the checked files (\(RadixFormatters.size((row.bundleBytes ?? 0) + selectedBytes))) will be moved to the Trash. You can put them back until it is emptied.", tableName: "Applications")
        }
        .confirmationDialog(
            String(localized: "Delete the data of \(row.name)?", table: "Applications"),
            isPresented: $confirmsReset
        ) {
            Button(String(localized: "Move to Trash", table: "Rooms"), role: .destructive) {
                model.remove(row, uninstall: false)
            }
        } message: {
            Text("The checked files (\(RadixFormatters.size(selectedBytes))) will be moved to the Trash. The app will start as if newly installed.", tableName: "Applications")
        }
    }
}

private struct DataItemRow: View {
    let item: AppDataItem
    @Binding var isSelected: Bool
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!isEnabled)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: item.entry.location.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            SizeText(bytes: item.bytes)
                .foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.entry.url])
            } label: {
                Label(String(localized: "Reveal in Finder", table: "Rooms"), systemImage: "magnifyingglass.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(String(localized: "Reveal in Finder", table: "Rooms"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }
}

private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 6))
            configuration.title
        }
    }
}
