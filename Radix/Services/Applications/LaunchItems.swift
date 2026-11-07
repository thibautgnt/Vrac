import Foundation

nonisolated enum LaunchItemScope: Int, CaseIterable, Hashable, Sendable {
    case userAgent
    case globalAgent
    case daemon
}

nonisolated struct LaunchItem: Identifiable, Hashable, Sendable {
    let label: String
    let plistURL: URL
    let scope: LaunchItemScope
    let program: String?
    let isLoaded: Bool
    let isDisabled: Bool

    var id: URL { plistURL }
}

nonisolated struct LaunchctlOutput: Sendable {
    let status: Int32
    let text: String
}

nonisolated enum LaunchItems {
    typealias Runner = @Sendable ([String]) -> LaunchctlOutput

    static func folders(home: URL) -> [(URL, LaunchItemScope)] {
        [
            (home.appendingPathComponent("Library/LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .globalAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .daemon)
        ]
    }

    static func load(home: URL, uid: uid_t = getuid(), run: Runner = launchctl) -> [LaunchItem] {
        let gui = "gui/\(uid)"
        return scan(
            folders: folders(home: home),
            loadedAgents: parseServices(run(["print", gui]).text),
            loadedDaemons: parseServices(run(["print", "system"]).text),
            agentOverrides: parseDisabled(run(["print-disabled", gui]).text),
            daemonOverrides: parseDisabled(run(["print-disabled", "system"]).text)
        )
    }

    static func scan(
        folders: [(URL, LaunchItemScope)],
        loadedAgents: Set<String>,
        loadedDaemons: Set<String>,
        agentOverrides: [String: Bool],
        daemonOverrides: [String: Bool]
    ) -> [LaunchItem] {
        folders.flatMap { folder, scope -> [LaunchItem] in
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "plist" }.compactMap { url in
                guard let plist = NSDictionary(contentsOf: url) as? [String: Any],
                      let label = plist["Label"] as? String else { return nil }
                let overrides = scope == .daemon ? daemonOverrides : agentOverrides
                return LaunchItem(
                    label: label,
                    plistURL: url,
                    scope: scope,
                    program: plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first,
                    isLoaded: (scope == .daemon ? loadedDaemons : loadedAgents).contains(label),
                    isDisabled: overrides[label] ?? (plist["Disabled"] as? Bool ?? false)
                )
            }
        }
        .sorted { ($0.scope.rawValue, $0.label.lowercased()) < ($1.scope.rawValue, $1.label.lowercased()) }
    }

    /// Labels listed in the `services = { … }` block of `launchctl print <domain>`.
    static func parseServices(_ output: String) -> Set<String> {
        var labels = Set<String>()
        var inServices = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "services = {" {
                inServices = true
            } else if inServices {
                if trimmed == "}" { break }
                if let label = trimmed.split(whereSeparator: \.isWhitespace).last {
                    labels.insert(String(label))
                }
            }
        }
        return labels
    }

    /// `"label" => disabled` lines of `launchctl print-disabled <domain>`, true when disabled.
    static func parseDisabled(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            result[label] = state == "disabled" || state == "true"
        }
        return result
    }

    /// Disables (and unloads) or enables (and loads) a job of `~/Library/LaunchAgents`.
    /// Returns launchctl's message when it fails.
    static func setEnabled(_ enabled: Bool, item: LaunchItem, uid: uid_t = getuid(), run: Runner = launchctl) -> String? {
        guard item.scope == .userAgent else { return nil }
        let target = "gui/\(uid)/\(item.label)"
        let toggle = run([enabled ? "enable" : "disable", target])
        guard toggle.status == 0 else { return message(toggle) }
        // Unloading a job that is not loaded, or loading one that already is, fails harmlessly.
        if enabled, !item.isLoaded {
            let load = run(["bootstrap", "gui/\(uid)", item.plistURL.path])
            if load.status != 0 { return message(load) }
        } else if !enabled, item.isLoaded {
            let unload = run(["bootout", target])
            if unload.status != 0 { return message(unload) }
        }
        return nil
    }

    /// The installed app a job comes from: the bundle its program lives in, else the app
    /// whose bundle id is the label or a dot-bounded prefix of it.
    static func owner(of item: LaunchItem, among apps: [InstalledApp]) -> InstalledApp? {
        if let program = item.program, let range = program.range(of: ".app/") {
            let bundlePath = String(program[..<range.lowerBound]) + ".app"
            if let app = apps.first(where: { $0.url.path == bundlePath || $0.url.resolvingSymlinksInPath().path == bundlePath }) {
                return app
            }
        }
        let ids = Set(apps.compactMap { $0.bundleID?.lowercased() })
        guard let id = AppLibraryMatching.owner(of: item.label, in: ids) else { return nil }
        return apps.first { $0.bundleID?.lowercased() == id }
    }

    static let launchctl: Runner = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return LaunchctlOutput(status: -1, text: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return LaunchctlOutput(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
    }

    private static func message(_ output: LaunchctlOutput) -> String {
        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "launchctl: \(output.status)" : text
    }
}
