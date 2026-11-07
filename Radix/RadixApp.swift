import AppKit
import Sparkle
import SwiftUI

@main
struct RadixApp: App {
    @StateObject private var appModel = AppModel()
    @StateObject private var softwareUpdates: SoftwareUpdateModel
    private let updaterController: SPUStandardUpdaterController

    init() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = updaterController
        _softwareUpdates = StateObject(wrappedValue: SoftwareUpdateModel(updater: updaterController.updater))
    }

    var body: some Scene {
        Window("Vrac", id: "main") {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 1180, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
        }
        .defaultSize(width: 1480, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            RadixCommands(
                appModel: appModel,
                scanState: appModel.scanState,
                navigation: appModel.navigation,
                workspaceTour: appModel.workspaceTour
            )
        }

        Settings {
            SettingsView(softwareUpdates: softwareUpdates)
                .environmentObject(appModel)
        }
    }
}
