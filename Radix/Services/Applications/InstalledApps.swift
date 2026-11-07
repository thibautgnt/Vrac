import CoreServices
import Foundation
import Security

nonisolated struct InstalledApp: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let bundleID: String?
    let version: String?
    let teamID: String?
    let isAppStore: Bool
    let isSystemProtected: Bool

    var id: URL { url }
    var isApple: Bool { bundleID.map(AppLibraryMatching.isAppleIdentifier) ?? false }
}

nonisolated enum AppLastUse: Hashable, Sendable {
    case unknown
    case never
    case date(Date)
}

nonisolated enum InstalledApps {
    static func defaultRoots(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    static let systemRoots = [
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Library/CoreServices")
    ]

    static func discover(in roots: [URL], teamID: (URL) -> String? = signingTeamID) -> [InstalledApp] {
        var seen = Set<String>()
        return roots
            .flatMap { appBundles(in: $0) }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .map { app(at: $0, teamID: teamID) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `.app` bundles directly in `folder` or one folder down (Utilities, vendor folders).
    static func appBundles(in folder: URL, depth: Int = 1) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.flatMap { child -> [URL] in
            if child.pathExtension == "app" { return [child] }
            guard depth > 0, (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return [] }
            return appBundles(in: child, depth: depth - 1)
        }
    }

    static func app(at url: URL, teamID: (URL) -> String? = signingTeamID) -> InstalledApp {
        let resolved = url.resolvingSymlinksInPath()
        let info = infoDictionary(of: resolved)
        let readOnly = (try? resolved.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
        return InstalledApp(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            bundleID: info["CFBundleIdentifier"] as? String,
            version: (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String),
            teamID: teamID(resolved),
            isAppStore: FileManager.default.fileExists(atPath: resolved.appendingPathComponent("Contents/_MASReceipt").path),
            isSystemProtected: readOnly || resolved.path.hasPrefix("/System/")
        )
    }

    static func infoDictionary(of bundle: URL) -> [String: Any] {
        // iOS apps installed on a Mac keep their Info.plist in WrappedBundle.
        for relative in ["Contents/Info.plist", "WrappedBundle/Info.plist", "Info.plist"] {
            if let info = NSDictionary(contentsOf: bundle.appendingPathComponent(relative)) as? [String: Any] {
                return info
            }
        }
        return [:]
    }

    /// Bundle identifiers of helpers, login items and extensions shipped inside an app.
    static func nestedBundleIDs(in app: URL) -> [String] {
        let contents = app.resolvingSymlinksInPath().appendingPathComponent("Contents")
        let places = ["Library/LoginItems", "Library/LaunchServices", "Library/SystemExtensions", "PlugIns", "Helpers", "XPCServices", "Extensions", "Applications", "MacOS"]
        return places.flatMap { place -> [String] in
            let children = (try? FileManager.default.contentsOfDirectory(
                at: contents.appendingPathComponent(place),
                includingPropertiesForKeys: nil
            )) ?? []
            return children.compactMap { infoDictionary(of: $0)["CFBundleIdentifier"] as? String }
        }
    }

    static func signingTeamID(_ url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else {
            return nil
        }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func lastUse(of url: URL) -> AppLastUse {
        guard let item = MDItemCreateWithURL(nil, url as CFURL),
              MDItemCopyAttribute(item, kMDItemContentType) != nil else { return .unknown }
        guard let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date else { return .never }
        return .date(date)
    }
}
