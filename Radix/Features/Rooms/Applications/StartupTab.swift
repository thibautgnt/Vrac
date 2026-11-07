import AppKit
import SwiftUI

struct StartupTab: View {
    @ObservedObject var model: ApplicationsRoomModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                Text("Programs that macOS starts by itself. Login items that apps register on their own are listed in System Settings.", tableName: "Applications")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 560, alignment: .leading)
                Spacer()
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(String(localized: "Open Login Items", table: "Applications"), systemImage: "gearshape")
                }
            }
            .padding(.horizontal, 28)

            if model.launchItems.isEmpty {
                RoomEmptyState(
                    title: String(localized: "No startup items", table: "Applications"),
                    message: String(localized: "Nothing in LaunchAgents or LaunchDaemons.", table: "Applications"),
                    systemImage: "power"
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(LaunchItemScope.allCases, id: \.self) { scope in
                        let items = model.launchItems.filter { $0.scope == scope }
                        if !items.isEmpty {
                            Section {
                                ForEach(items) { item in
                                    LaunchItemRow(model: model, item: item, owner: model.launchOwners[item.id])
                                }
                            } header: {
                                Text(scope.title)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

private extension LaunchItemScope {
    var title: String {
        switch self {
        case .userAgent: String(localized: "Your agents", table: "Applications")
        case .globalAgent: String(localized: "Agents for all users", table: "Applications")
        case .daemon: String(localized: "System daemons", table: "Applications")
        }
    }
}

private struct LaunchItemRow: View {
    @ObservedObject var model: ApplicationsRoomModel
    let item: LaunchItem
    let owner: InstalledApp?

    private var program: String? { item.program.map { ($0 as NSString).abbreviatingWithTildeInPath } }

    var body: some View {
        HStack(spacing: 10) {
            if let owner {
                AppIcon(url: owner.url, size: 26)
            } else {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: owner?.name ?? item.label)
                        .lineLimit(1)
                    if item.isDisabled {
                        StatusBadge(text: String(localized: "Disabled", table: "Applications"), color: .secondary)
                    } else if item.isLoaded {
                        StatusBadge(text: String(localized: "Loaded", table: "Applications"), color: .green)
                    } else {
                        StatusBadge(text: String(localized: "Not loaded", table: "Applications"), color: .secondary)
                    }
                }
                Text(verbatim: owner == nil ? (program ?? "") : [item.label, program].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.plistURL])
            } label: {
                Label(String(localized: "Reveal in Finder", table: "Rooms"), systemImage: "magnifyingglass.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(String(localized: "Reveal in Finder", table: "Rooms"))
            if item.scope == .userAgent {
                if model.togglingItems.contains(item.id) {
                    ProgressView().controlSize(.small)
                }
                Toggle(
                    String(localized: "Enabled", table: "Applications"),
                    isOn: Binding(get: { !item.isDisabled }, set: { model.setEnabled($0, item: item) })
                )
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(model.togglingItems.contains(item.id))
            } else {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
                    .frame(width: 32)
                    .help(String(localized: "Only an administrator can change this item.", table: "Applications"))
                    .accessibilityLabel(String(localized: "Only an administrator can change this item.", table: "Applications"))
            }
        }
        .padding(.vertical, 3)
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }
}
