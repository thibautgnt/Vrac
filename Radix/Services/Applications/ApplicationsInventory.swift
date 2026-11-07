import Foundation

/// Everything the Applications room lists, found without measuring sizes.
nonisolated struct ApplicationsInventory: Sendable {
    var apps: [InstalledApp] = []
    var associations: [URL: [LibraryEntry]] = [:]
    var leftovers: [LeftoverGroup] = []
    var launchItems: [LaunchItem] = []

    static func load(
        home: URL,
        appRoots: [URL]? = nil,
        systemRoots: [URL] = InstalledApps.systemRoots,
        teamID: (URL) -> String? = InstalledApps.signingTeamID,
        isRegistered: (String) -> Bool = AppLibraryMatching.isRegisteredWithLaunchServices,
        launchItems: (() -> [LaunchItem])? = nil
    ) -> ApplicationsInventory {
        var inventory = ApplicationsInventory()
        inventory.apps = InstalledApps.discover(in: appRoots ?? InstalledApps.defaultRoots(home: home), teamID: teamID)
        inventory.launchItems = launchItems?() ?? LaunchItems.load(home: home)

        let entries = AppLibraryMatching.scan(library: home.appendingPathComponent("Library"))
        let systemApps = systemRoots.flatMap { InstalledApps.appBundles(in: $0) }
        let appIDs = Set((inventory.apps.compactMap(\.bundleID) + systemApps.compactMap {
            InstalledApps.infoDictionary(of: $0)["CFBundleIdentifier"] as? String
        }).map { $0.lowercased() })

        var teamCounts: [String: Int] = [:]
        for team in inventory.apps.compactMap(\.teamID) { teamCounts[team, default: 0] += 1 }
        let sharedTeams = Set(teamCounts.filter { $0.value > 1 }.keys)
        for app in inventory.apps {
            inventory.associations[app.url] = AppLibraryMatching.associations(
                for: app, in: entries, appBundleIDs: appIDs, sharedTeamIDs: sharedTeams
            )
        }

        let nestedIDs = inventory.apps.flatMap { InstalledApps.nestedBundleIDs(in: $0.url) }
        inventory.leftovers = AppLibraryMatching.leftovers(
            in: entries,
            knownIdentifiers: appIDs.union(nestedIDs).union(inventory.launchItems.map(\.label)),
            knownTeamIDs: Set(teamCounts.keys),
            isRegistered: isRegistered
        )
        return inventory
    }
}
