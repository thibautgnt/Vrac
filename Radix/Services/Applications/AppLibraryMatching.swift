import AppKit
import Foundation

nonisolated enum AppLibraryLocation: String, CaseIterable, Hashable, Sendable {
    case applicationSupport = "Application Support"
    case caches = "Caches"
    case containers = "Containers"
    case groupContainers = "Group Containers"
    case preferences = "Preferences"
    case preferencesByHost = "Preferences/ByHost"
    case savedState = "Saved Application State"
    case logs = "Logs"
    case httpStorages = "HTTPStorages"
    case webKit = "WebKit"
    case cookies = "Cookies"
    case launchAgents = "LaunchAgents"
    case applicationScripts = "Application Scripts"
}

nonisolated struct LibraryEntry: Identifiable, Hashable, Sendable {
    let location: AppLibraryLocation
    let url: URL

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

nonisolated struct LeftoverGroup: Identifiable, Hashable, Sendable {
    let identifier: String
    let entries: [LibraryEntry]

    var id: String { identifier.lowercased() }
}

/// Matches `~/Library` items to apps by bundle identifier. Conservative on purpose:
/// anything ambiguous belongs to nobody, so it is neither uninstalled nor reported as a leftover.
nonisolated enum AppLibraryMatching {
    static func scan(library: URL) -> [LibraryEntry] {
        AppLibraryLocation.allCases.flatMap { location -> [LibraryEntry] in
            let names = (try? FileManager.default.contentsOfDirectory(
                atPath: library.appendingPathComponent(location.rawValue).path
            )) ?? []
            return names
                .filter { !$0.hasPrefix(".") && !(location == .preferences && $0 == "ByHost") }
                .map { LibraryEntry(location: location, url: library.appendingPathComponent(location.rawValue).appendingPathComponent($0)) }
        }
    }

    /// Identifiers written by libraries, updaters and system tools that installed apps embed;
    /// they outlive no particular app.
    static let sharedIdentifierPrefixes = [
        "com.amplitude", "com.segment", "com.revenuecat", "com.plausiblelabs", "com.onevcat", "com.crashlytics",
        "com.mixpanel", "com.bugsnag", "com.posthog", "com.google.firebase", "com.microsoft.appcenter", "io.sentry",
        "org.sparkle-project", "org.swift", "org.cups", "org.webkit", "org.python", "org.llvm", "jetbrains"
    ]

    /// Group containers, and Application Scripts named like them, use `TEAMID.` or `group.` names.
    static func isGroupStyle(_ entry: LibraryEntry) -> Bool {
        entry.location == .groupContainers
            || (entry.location == .applicationScripts && (teamPrefix(of: entry.name) != nil || entry.name.lowercased().hasPrefix("group.")))
    }

    static func isAppleIdentifier(_ identifier: String) -> Bool {
        let lower = identifier.lowercased()
        // Shortcuts still uses the identifiers of Workflow, the app Apple bought.
        return ["com.apple", "group.com.apple", "groups.com.apple", "systemgroup", "is.workflow", "group.is.workflow"]
            .contains { lower == $0 || lower.hasPrefix($0 + ".") }
    }

    /// The identifier an item is named after: `com.foo.app.plist`, `com.foo.app.savedState`
    /// and `ByHost/com.foo.app.<host UUID>.plist` all give `com.foo.app`.
    static func identifier(of entry: LibraryEntry) -> String {
        var name = entry.name
        for suffix in [".plist", ".savedState", ".binarycookies"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        if entry.location == .preferencesByHost, let dot = name.lastIndex(of: ".") {
            let host = name[name.index(after: dot)...]
            if UUID(uuidString: String(host)) != nil || (host.count == 12 && host.allSatisfy(\.isHexDigit)) {
                name = String(name[..<dot])
            }
        }
        return name
    }

    /// `ABCDE12345.rest` → (`ABCDE12345`, `rest`) for team-scoped group containers.
    static func teamPrefix(of name: String) -> (team: String, rest: String)? {
        guard let dot = name.firstIndex(of: ".") else { return nil }
        let team = name[..<dot]
        guard team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { return nil }
        return (String(team), String(name[name.index(after: dot)...]))
    }

    static func isReverseDNS(_ identifier: String) -> Bool {
        identifier.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9_-]+){2,}$"#, options: .regularExpression) != nil
    }

    /// The longest identifier in `known` that is `key` itself or a dot-bounded prefix of it.
    static func owner(of key: String, in known: Set<String>) -> String? {
        var candidate = key.lowercased()
        while true {
            if known.contains(candidate) { return candidate }
            guard let dot = candidate.lastIndex(of: ".") else { return nil }
            candidate = String(candidate[..<dot])
        }
    }

    /// `appBundleIDs` (lowercased, all installed apps) sends `com.foo.app.beta` data to that app, not to `com.foo.app`;
    /// team containers of `sharedTeamIDs` belong to several apps and are never matched.
    static func associations(
        for app: InstalledApp,
        in entries: [LibraryEntry],
        appBundleIDs: Set<String>,
        sharedTeamIDs: Set<String>
    ) -> [LibraryEntry] {
        let bundleID = app.bundleID?.lowercased()
        let known = bundleID.map { appBundleIDs.union([$0]) } ?? appBundleIDs
        return entries.filter { entry in
            if !app.isApple, isAppleIdentifier(entry.name) || teamPrefix(of: entry.name).map({ isAppleIdentifier($0.rest) }) == true {
                return false
            }
            if [.applicationSupport, .caches].contains(entry.location), !app.name.isEmpty, entry.name == app.name {
                return true
            }
            guard let bundleID else { return false }
            if isGroupStyle(entry) {
                if let (team, rest) = teamPrefix(of: entry.name) {
                    if let appTeam = app.teamID, appTeam == team, !sharedTeamIDs.contains(team) { return true }
                    return owner(of: rest, in: known) == bundleID
                }
                let key = entry.name.lowercased().hasPrefix("group.") ? String(entry.name.dropFirst(6)) : entry.name
                return owner(of: key, in: known) == bundleID
            }
            return owner(of: identifier(of: entry), in: known) == bundleID
        }
    }

    /// Items named after a bundle identifier that no installed app, nested bundle, launch job or Launch Services entry claims.
    static func leftovers(
        in entries: [LibraryEntry],
        knownIdentifiers: Set<String>,
        knownTeamIDs: Set<String>,
        isRegistered: (String) -> Bool = isRegisteredWithLaunchServices
    ) -> [LeftoverGroup] {
        let known = Set(knownIdentifiers.map { $0.lowercased() })
        let knownVendors = Set(known.compactMap(vendor))
        var registered: [String: Bool] = [:]
        func claimed(_ key: String) -> Bool {
            if owner(of: key, in: known) != nil { return true }
            // Shared vendor folders and helpers of a vendor whose app is installed are ambiguous.
            if let vendor = vendor(of: key), knownVendors.contains(vendor) { return true }
            let parent = key.split(separator: ".").dropLast().joined(separator: ".")
            return [key, parent].contains { candidate in
                if let cached = registered[candidate] { return cached }
                let result = isReverseDNS(candidate) && isRegistered(candidate)
                registered[candidate] = result
                return result
            }
        }

        var groups: [String: (identifier: String, entries: [LibraryEntry])] = [:]
        for entry in entries {
            let identifier: String
            if isGroupStyle(entry) {
                // `group.<id>` containers can be shared by apps with unrelated ids; only team-scoped ones are judged.
                guard let (team, rest) = teamPrefix(of: entry.name),
                      !knownTeamIDs.contains(team),
                      !isAppleIdentifier(rest),
                      !claimed(rest.lowercased().hasPrefix("group.") ? String(rest.dropFirst(6)) : rest) else { continue }
                identifier = entry.name
            } else {
                identifier = self.identifier(of: entry)
                let lower = identifier.lowercased()
                guard isReverseDNS(identifier),
                      !isAppleIdentifier(identifier),
                      !sharedIdentifierPrefixes.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") }),
                      !claimed(identifier) else { continue }
            }
            groups[identifier.lowercased(), default: (identifier, [])].entries.append(entry)
        }
        return groups.values
            .map { LeftoverGroup(identifier: $0.identifier, entries: $0.entries) }
            .sorted { $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending }
    }

    static func isRegisteredWithLaunchServices(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    private static func vendor(of identifier: String) -> String? {
        let parts = identifier.lowercased().split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return parts.prefix(2).joined(separator: ".")
    }
}
