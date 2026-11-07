import Foundation
import Testing
@testable import RadixCore

struct ApplicationsRoomTests {
    private final class Fixture {
        let root: URL
        var home: URL { root.appendingPathComponent("home") }
        var library: URL { home.appendingPathComponent("Library") }
        var apps: URL { root.appendingPathComponent("Applications") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ApplicationsRoom-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func app(_ relativePath: String, id: String?, version: String = "1.0", appStore: Bool = false) throws -> URL {
            let url = apps.appendingPathComponent(relativePath)
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleShortVersionString": version]
            info["CFBundleIdentifier"] = id
            try (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
            if appStore {
                try FileManager.default.createDirectory(at: contents.appendingPathComponent("_MASReceipt"), withIntermediateDirectories: true)
            }
            return url
        }

        func nested(_ app: URL, _ place: String, id: String) throws {
            let contents = app.appendingPathComponent("Contents/\(place)/Helper.app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try (["CFBundleIdentifier": id] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        }

        func library(_ paths: String...) throws {
            for path in paths {
                let url = library.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url)
            }
        }
    }

    private func app(_ name: String, _ id: String?, team: String? = nil) -> InstalledApp {
        InstalledApp(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, bundleID: id, version: nil, teamID: team, isAppStore: false, isSystemProtected: false)
    }

    private func entry(_ location: AppLibraryLocation, _ name: String) -> LibraryEntry {
        LibraryEntry(location: location, url: URL(fileURLWithPath: "/L/\(location.rawValue)/\(name)"))
    }

    @Test
    func testDiscoversAppsOneLevelDeepWithMetadata() throws {
        let fixture = try Fixture()
        try fixture.app("Editor.app", id: "com.acme.editor", version: "2.1", appStore: true)
        try fixture.app("Utilities/Tool.app", id: "com.acme.tool")
        try fixture.app("Vendor/Deep/Hidden.app", id: "com.acme.hidden")

        let apps = InstalledApps.discover(in: [fixture.apps], teamID: { _ in nil })

        #expect(apps.map(\.name) == ["Editor", "Tool"])
        #expect(apps[0].version == "2.1")
        #expect(apps[0].isAppStore)
        #expect(!apps[1].isAppStore)
        #expect(!apps[0].isSystemProtected)
    }

    @Test
    func testAssociationsUseExactOrDotBoundedBundleIDs() {
        let editor = app("Editor", "com.acme.editor")
        let entries = [
            entry(.applicationSupport, "com.acme.editor"),
            entry(.applicationSupport, "Editor"),
            entry(.applicationSupport, "Editor Pro"),
            entry(.caches, "com.acme.editor.ShipIt"),
            entry(.caches, "com.acme.editorial"),
            entry(.caches, "com.acme.editor.beta"),
            entry(.logs, "Editor"),
            entry(.preferences, "com.acme.editor.plist"),
            entry(.preferencesByHost, "com.acme.editor.0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0.plist"),
            entry(.savedState, "com.acme.editor.savedState"),
            entry(.cookies, "com.acme.editor.binarycookies"),
            entry(.containers, "com.acme.editor.extension"),
            entry(.preferences, "com.apple.editor.plist")
        ]
        let ids: Set<String> = ["com.acme.editor", "com.acme.editor.beta"]

        let matched = AppLibraryMatching.associations(for: editor, in: entries, appBundleIDs: ids, sharedTeamIDs: [])

        #expect(matched.map(\.name) == [
            "com.acme.editor", "Editor", "com.acme.editor.ShipIt",
            "com.acme.editor.plist", "com.acme.editor.0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0.plist",
            "com.acme.editor.savedState", "com.acme.editor.binarycookies", "com.acme.editor.extension"
        ])
    }

    @Test
    func testAppleDataIsNeverMatchedToThirdPartyApps() {
        let notes = app("Notes", "com.apple")
        let thirdParty = app("Notes", "org.notes.app")
        let entries = [
            entry(.applicationSupport, "Notes"),
            entry(.containers, "com.apple.Notes"),
            entry(.groupContainers, "group.com.apple.notes"),
            entry(.groupContainers, "ABCDE12345.com.apple.notes")
        ]

        let matched = AppLibraryMatching.associations(for: thirdParty, in: entries, appBundleIDs: ["org.notes.app"], sharedTeamIDs: [])

        #expect(matched.map(\.name) == ["Notes"])
        #expect(notes.isApple)
    }

    @Test
    func testGroupContainersMatchTeamOnlyWhenNotShared() {
        let teamApp = app("Editor", "com.acme.editor", team: "ABCDE12345")
        let entries = [
            entry(.groupContainers, "ABCDE12345.shared"),
            entry(.groupContainers, "group.com.acme.editor"),
            entry(.groupContainers, "ZZZZZ99999.com.acme.editor.widgets"),
            entry(.groupContainers, "group.com.acme")
        ]

        let alone = AppLibraryMatching.associations(for: teamApp, in: entries, appBundleIDs: ["com.acme.editor"], sharedTeamIDs: [])
        let shared = AppLibraryMatching.associations(for: teamApp, in: entries, appBundleIDs: ["com.acme.editor"], sharedTeamIDs: ["ABCDE12345"])

        #expect(alone.map(\.name) == ["ABCDE12345.shared", "group.com.acme.editor", "ZZZZZ99999.com.acme.editor.widgets"])
        #expect(shared.map(\.name) == ["group.com.acme.editor", "ZZZZZ99999.com.acme.editor.widgets"])
    }

    @Test
    func testLeftoversSkipKnownAppleAmbiguousAndRegisteredItems() {
        let entries = [
            entry(.applicationSupport, "com.gone.app"),
            entry(.preferences, "com.gone.app.plist"),
            entry(.caches, "com.acme.editor.ShipIt"),
            entry(.caches, "com.acme.updater"),
            entry(.preferences, "com.apple.Safari.plist"),
            entry(.containers, "is.workflow.my.app"),
            entry(.applicationSupport, "Some Folder"),
            entry(.preferences, "loginwindow.plist"),
            entry(.preferences, "org.elsewhere.app.plist"),
            entry(.preferences, "org.elsewhere.app.helper.plist"),
            entry(.groupContainers, "group.org.orphan.shared"),
            entry(.groupContainers, "ABCDE12345.shared"),
            entry(.groupContainers, "QWERT67890.com.old.thing"),
            entry(.groupContainers, "systemgroup.com.apple.x"),
            entry(.applicationScripts, "ABCDE12345.com.acme.shared"),
            entry(.applicationScripts, "group.org.orphan.shared"),
            entry(.applicationScripts, "QWERT67890.com.old.thing"),
            entry(.preferences, "com.amplitude.storage.default.plist"),
            entry(.caches, "org.swift.swiftpm")
        ]

        let groups = AppLibraryMatching.leftovers(
            in: entries,
            knownIdentifiers: ["com.acme.editor"],
            knownTeamIDs: ["ABCDE12345"],
            isRegistered: { $0 == "org.elsewhere.app" }
        )

        #expect(groups.map(\.identifier) == ["com.gone.app", "QWERT67890.com.old.thing"])
        #expect(groups[0].entries.count == 2)
        #expect(groups[1].entries.map(\.location) == [.groupContainers, .applicationScripts])
    }

    @Test
    func testInventoryOnFixtureHome() throws {
        let fixture = try Fixture()
        try fixture.nested(try fixture.app("Editor.app", id: "com.acme.editor"), "Library/LoginItems", id: "net.acme.launcher")
        try fixture.library(
            "Application Support/com.acme.editor/db",
            "Preferences/com.acme.editor.plist",
            "Preferences/net.acme.launcher.plist",
            "Caches/com.removed.tool/blob",
            "Preferences/com.apple.finder.plist"
        )

        let inventory = ApplicationsInventory.load(
            home: fixture.home,
            appRoots: [fixture.apps],
            systemRoots: [],
            teamID: { _ in nil },
            isRegistered: { _ in false },
            launchItems: { [] }
        )

        #expect(inventory.apps.map(\.bundleID) == ["com.acme.editor"])
        #expect(inventory.associations[inventory.apps[0].url]?.map(\.name).sorted() == ["com.acme.editor", "com.acme.editor.plist"])
        #expect(inventory.leftovers.map(\.identifier) == ["com.removed.tool"])
    }

    @Test
    func testParsesLaunchctlOutputs() {
        let services = """
        gui/501 = {
        \ttype = login
        \tservices = {
        \t\t    5714   (pe) \tcom.apple.syncdefaultsd
        \t\t       0      - \tcom.acme.agent
        \t}
        \tendpoints = {
        \t\t"com.other.endpoint" = {
        \t}
        }
        """
        let disabled = """
        \tdisabled services = {
        \t\t"com.acme.agent" => disabled
        \t\t"com.acme.other" => enabled
        \t\t"com.legacy.job" => true
        \t}
        """

        #expect(LaunchItems.parseServices(services) == ["com.apple.syncdefaultsd", "com.acme.agent"])
        #expect(LaunchItems.parseDisabled(disabled) == ["com.acme.agent": true, "com.acme.other": false, "com.legacy.job": true])
    }

    @Test
    func testScansLaunchFoldersAndGuessesOwner() throws {
        let fixture = try Fixture()
        let agents = fixture.library.appendingPathComponent("LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try (["Label": "com.acme.editor.helper", "ProgramArguments": ["/opt/acme/helper", "--run"]] as NSDictionary)
            .write(to: agents.appendingPathComponent("com.acme.editor.helper.plist"))
        try (["Label": "org.tool.sync", "Program": "/Applications/Sync.app/Contents/MacOS/sync", "Disabled": true] as NSDictionary)
            .write(to: agents.appendingPathComponent("org.tool.sync.plist"))

        let items = LaunchItems.scan(
            folders: [(agents, .userAgent)],
            loadedAgents: ["com.acme.editor.helper"],
            loadedDaemons: [],
            agentOverrides: [:],
            daemonOverrides: [:]
        )
        let apps = [app("Editor", "com.acme.editor"), app("Sync", "com.sync.app")]

        #expect(items.map(\.label) == ["com.acme.editor.helper", "org.tool.sync"])
        #expect(items[0].program == "/opt/acme/helper")
        #expect(items[0].isLoaded && !items[0].isDisabled)
        #expect(!items[1].isLoaded && items[1].isDisabled)
        #expect(LaunchItems.owner(of: items[0], among: apps)?.name == "Editor")
        #expect(LaunchItems.owner(of: items[1], among: apps)?.name == "Sync")
    }

    @Test
    func testToggleRunsDisableThenBootout() {
        final class Calls: @unchecked Sendable { var list: [[String]] = [] }
        let calls = Calls()
        let item = LaunchItem(label: "com.acme.agent", plistURL: URL(fileURLWithPath: "/tmp/a.plist"), scope: .userAgent, program: nil, isLoaded: true, isDisabled: false)

        let error = LaunchItems.setEnabled(false, item: item, uid: 501) { arguments in
            calls.list.append(arguments)
            return LaunchctlOutput(status: arguments[0] == "bootout" ? 5 : 0, text: arguments[0] == "bootout" ? "Boot-out failed: 5" : "")
        }

        #expect(calls.list == [["disable", "gui/501/com.acme.agent"], ["bootout", "gui/501/com.acme.agent"]])
        #expect(error == "Boot-out failed: 5")

        calls.list = []
        let notLoaded = LaunchItem(label: "com.acme.agent", plistURL: URL(fileURLWithPath: "/tmp/a.plist"), scope: .userAgent, program: nil, isLoaded: false, isDisabled: true)
        #expect(LaunchItems.setEnabled(true, item: notLoaded, uid: 501) { calls.list.append($0); return LaunchctlOutput(status: 0, text: "") } == nil)
        #expect(calls.list == [["enable", "gui/501/com.acme.agent"], ["bootstrap", "gui/501", "/tmp/a.plist"]])

        let daemon = LaunchItem(label: "com.acme.d", plistURL: URL(fileURLWithPath: "/tmp/d.plist"), scope: .daemon, program: nil, isLoaded: true, isDisabled: false)
        calls.list = []
        _ = LaunchItems.setEnabled(false, item: daemon, uid: 501) { calls.list.append($0); return LaunchctlOutput(status: 0, text: "") }
        #expect(calls.list.isEmpty)
    }

    @Test
    func testSamplesOwnProcess() throws {
        let first = try #require(ProcessUsage.sample(pid: getpid()))
        var sink = 0
        for value in 0..<2_000_000 { sink &+= value }
        #expect(sink != 0)
        let second = try #require(ProcessUsage.sample(pid: getpid()))
        #expect(first.memoryBytes > 0)
        #expect(ProcessUsage.cpuPercent(from: first, to: second) >= 0)
        #expect(ProcessUsage.sample(pid: -1) == nil)
    }
}
