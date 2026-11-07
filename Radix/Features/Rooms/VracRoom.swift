import SwiftUI

enum VracRoom: String, CaseIterable, Identifiable {
    case overview
    case cleanup
    case duplicates
    case applications
    case compress
    case monitor

    static let sidebarTagPrefix = "room."

    var id: String { rawValue }
    var sidebarTag: String { Self.sidebarTagPrefix + rawValue }

    init?(sidebarTag: String) {
        guard sidebarTag.hasPrefix(Self.sidebarTagPrefix) else { return nil }
        self.init(rawValue: String(sidebarTag.dropFirst(Self.sidebarTagPrefix.count)))
    }

    var title: String {
        switch self {
        case .overview: String(localized: "Overview", table: "Rooms")
        case .cleanup: String(localized: "Cleanup", table: "Rooms")
        case .duplicates: String(localized: "Duplicates", table: "Rooms")
        case .applications: String(localized: "Applications", table: "Rooms")
        case .compress: String(localized: "Compress", table: "Rooms")
        case .monitor: String(localized: "Monitor", table: "Rooms")
        }
    }

    var subtitle: String {
        switch self {
        case .overview: String(localized: "Your disk at a glance", table: "Rooms")
        case .cleanup: String(localized: "Caches, logs, build files and leftovers", table: "Rooms")
        case .duplicates: String(localized: "Identical files, compared byte for byte", table: "Rooms")
        case .applications: String(localized: "Apps, their data and startup items", table: "Rooms")
        case .compress: String(localized: "Shrink videos and photos instead of deleting them", table: "Rooms")
        case .monitor: String(localized: "CPU, memory, ports and battery in real time", table: "Rooms")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "chart.pie.fill"
        case .cleanup: "sparkles"
        case .duplicates: "doc.on.doc.fill"
        case .applications: "square.grid.2x2.fill"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .monitor: "gauge.with.dots.needle.67percent"
        }
    }

    var tint: Color {
        switch self {
        case .overview: .blue
        case .cleanup: .teal
        case .duplicates: .orange
        case .applications: .indigo
        case .compress: .pink
        case .monitor: .green
        }
    }
}
