import AppKit
import SwiftUI

struct LeftoversTab: View {
    @ObservedObject var model: ApplicationsRoomModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                RoomStat(
                    value: model.leftovers.contains { $0.sizes.isEmpty } ? "…" : RadixFormatters.size(model.leftovers.reduce(0) { $0 + $1.bytes }),
                    caption: String(localized: "Leftovers found", table: "Applications"),
                    tint: VracRoom.applications.tint
                )
                Text("Files left in your Library by apps that are no longer installed. Nothing is checked for you: look at each item before removing it.", tableName: "Applications")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)

            if model.leftovers.isEmpty {
                RoomEmptyState(
                    title: String(localized: "No leftovers found", table: "Applications"),
                    message: String(localized: "No files from uninstalled apps were found in your Library.", table: "Applications"),
                    systemImage: "checkmark.circle"
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.leftovers) { row in
                        LeftoverGroupRow(
                            row: row,
                            isSelected: Binding(
                                get: { model.leftoverSelection.contains(row.id) },
                                set: { selected in
                                    if selected { model.leftoverSelection.insert(row.id) } else { model.leftoverSelection.remove(row.id) }
                                }
                            )
                        )
                    }
                }
                .listStyle(.inset)
                TrashSelectionBar(
                    itemCount: model.selectedLeftoverItems.count,
                    bytes: model.selectedLeftoverItems.reduce(0) { $0 + $1.bytes },
                    isWorking: model.isWorking,
                    moveToTrash: model.trashSelectedLeftovers
                )
            }
        }
    }
}

private struct LeftoverGroupRow: View {
    let row: LeftoverRow
    @Binding var isSelected: Bool
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(row.group.entries) { entry in
                RoomFileRow(url: entry.url, bytes: row.sizes[entry.url] ?? 0, detail: entry.location.rawValue)
                    .padding(.leading, 26)
            }
        } label: {
            HStack(spacing: 10) {
                Toggle(isOn: $isSelected) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: row.group.identifier)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: Set(row.group.entries.map(\.location.rawValue)).sorted().joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(row.group.entries.count) items", tableName: "Applications")
                    .foregroundStyle(.secondary)
                SizeText(bytes: row.sizes.isEmpty ? nil : row.bytes)
                    .frame(minWidth: 70, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }
}
