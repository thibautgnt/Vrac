import AppKit
import SwiftUI

struct ApplicationsRoomView: View {
    @ObservedObject private var model = ApplicationsRoomModel.shared

    var body: some View {
        RoomPage(room: .applications, scrolls: false) {
            HStack(spacing: 12) {
                if model.isMeasuring {
                    ProgressView().controlSize(.small)
                }
                Picker(String(localized: "Section", table: "Applications"), selection: $model.tab) {
                    Text("Applications", tableName: "Applications").tag(ApplicationsRoomModel.Tab.apps)
                    Text("Leftovers", tableName: "Applications").tag(ApplicationsRoomModel.Tab.leftovers)
                    Text("Startup", tableName: "Applications").tag(ApplicationsRoomModel.Tab.startup)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button {
                    model.refresh()
                } label: {
                    Label(String(localized: "Refresh", table: "Applications"), systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help(String(localized: "Refresh", table: "Applications"))
                .disabled(model.isLoading || model.isWorking)
            }
        } content: {
            Group {
                if model.isLoading && model.rows.isEmpty {
                    ProgressView(String(localized: "Looking for apps…", table: "Applications"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch model.tab {
                    case .apps: AppsTab(model: model)
                    case .leftovers: LeftoversTab(model: model)
                    case .startup: StartupTab(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { model.loadIfNeeded() }
        .alert(item: $model.alert) { alert in
            if let url = alert.reveal {
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Reveal in Finder", tableName: "Rooms")) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    },
                    secondaryButton: .cancel(Text("OK", tableName: "Applications"))
                )
            } else {
                Alert(title: Text(alert.title), message: Text(alert.message))
            }
        }
    }
}

private struct AppsTab: View {
    @ObservedObject var model: ApplicationsRoomModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SearchField(text: $model.search)
                        .frame(maxWidth: 260)
                    Spacer()
                    Text("\(model.rows.count) apps", tableName: "Applications")
                        .foregroundStyle(.secondary)
                    Text(RadixFormatters.size(model.rows.reduce(0) { $0 + ($1.totalBytes ?? 0) }))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)
                AppsTable(model: model)
            }
            if let row = model.selectedRow {
                Divider()
                AppDetailView(model: model, row: row)
                    .frame(width: 360)
                    .id(row.id)
            }
        }
    }
}

private struct AppsTable: View {
    @ObservedObject var model: ApplicationsRoomModel

    var body: some View {
        Table(model.visibleRows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn(String(localized: "Name", table: "Applications"), value: \.name) { row in
                HStack(spacing: 8) {
                    AppIcon(url: row.app.url, size: 20)
                    Text(row.name).lineLimit(1)
                }
            }
            .width(min: 160, ideal: 220)
            TableColumn(String(localized: "Version", table: "Applications"), value: \.versionSort) { row in
                Text(verbatim: row.app.version ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 50, ideal: 70)
            TableColumn(String(localized: "App", table: "Applications"), value: \.bundleSort) { row in
                SizeText(bytes: row.bundleBytes)
            }
            .width(min: 60, ideal: 75)
            TableColumn(String(localized: "Data", table: "Applications"), value: \.dataSort) { row in
                SizeText(bytes: row.dataBytes)
            }
            .width(min: 60, ideal: 75)
            TableColumn(String(localized: "Total", table: "Applications"), value: \.totalSort) { row in
                SizeText(bytes: row.totalBytes).fontWeight(.medium)
            }
            .width(min: 60, ideal: 80)
            TableColumn(String(localized: "Last Used", table: "Applications"), value: \.lastUseSort) { row in
                LastUseText(lastUse: row.lastUse)
            }
            .width(min: 80, ideal: 110)
            TableColumn(String(localized: "Source", table: "Applications"), value: \.sourceSort) { row in
                Text(verbatim: row.source).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 80)
        }
        .tableStyle(.inset)
    }
}

struct AppIcon: View {
    let url: URL
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct SizeText: View {
    let bytes: Int64?

    var body: some View {
        Text(verbatim: bytes.map(RadixFormatters.size) ?? "…")
            .monospacedDigit()
            .foregroundStyle(bytes == nil ? .tertiary : .primary)
            .lineLimit(1)
    }
}

private struct LastUseText: View {
    let lastUse: AppLastUse?

    var body: some View {
        switch lastUse {
        case .date(let date):
            Text(date, format: .relative(presentation: .named)).lineLimit(1)
        case .never:
            Text("Never", tableName: "Applications").foregroundStyle(.secondary)
        case .unknown:
            Text("Unknown", tableName: "Applications").foregroundStyle(.tertiary)
        case nil:
            Text(verbatim: "…").foregroundStyle(.tertiary)
        }
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(String(localized: "Search apps", table: "Applications"), text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear search", table: "Applications"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(nsColor: .separatorColor))
        }
    }
}
