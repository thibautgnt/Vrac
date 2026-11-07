import SwiftUI

/// Lets a room open another room or the disk-map explorer on a folder.
struct VracNavigator {
    var explore: (URL) -> Void = { _ in }
    var openRoom: (VracRoom) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var vracNavigator = VracNavigator()
}

struct RoomDetailView: View {
    let room: VracRoom

    var body: some View {
        Group {
            switch room {
            case .overview: OverviewRoomView()
            case .cleanup: CleanupRoomView()
            case .duplicates: DuplicatesRoomView()
            case .applications: ApplicationsRoomView()
            case .compress: CompressRoomView()
            case .monitor: MonitorRoomView()
            }
        }
        .navigationTitle(room.title)
    }
}
