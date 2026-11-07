# AGENTS.md

## Vrac

Vrac is a personal, renamed fork of Radix (MIT, upstream remote `upstream`):
a native macOS 14+ disk-space analyzer and cleaner built with Swift 6.2,
SwiftUI, and Xcode 26+. Types, files, the Xcode project and the scheme keep
the Radix name so upstream can still be merged; only what the user sees says
Vrac. The UI language that matters is French.

## Vrac rooms

Besides the Radix disk-map workspace, the sidebar "Outils" section opens
rooms (`Radix/Features/Rooms/`): Overview, Cleanup, Duplicates, Applications,
Compress, Monitor.

- One folder per room: `Radix/Features/Rooms/<Room>/`, entry view
  `<Room>RoomView` (no init parameters). Build pages with the shared pieces in
  `Rooms/Shared/RoomComponents.swift`: `RoomPage`, `RoomCard`, `RoomStat`,
  `StorageSegmentBar`, `TrashSelectionBar`, `RoomEmptyState`, `RoomFileRow`.
- Navigation from a room: `@Environment(\.vracNavigator)` gives
  `explore(URL)` (open the disk map on a folder) and `openRoom(VracRoom)`.
- Room state must survive switching rooms: keep it in a `@MainActor final class
  <Room>RoomModel: ObservableObject` with `static let shared`, observed by the view.
- Non-UI logic (scanners, rules, parsers) goes in `Radix/Services/<Room>/`,
  is `nonisolated` where it runs off the main actor, is listed in
  `Package.swift` and gets Swift Testing tests in `RadixCoreTests/`.
- Deleting: never remove files directly. Selection, then `TrashSelectionBar`
  (confirmation), then `RoomTrash.moveToTrash` off the main actor. Never touch
  anything inside a package such as a Photos library, and never select by
  default anything whose loss the user would regret.
- Strings: English key, French translation, one catalog per room,
  `Radix/Features/Rooms/<Room>/<Room>.xcstrings`, used with
  `Text("Key", tableName: "<Room>")` or `String(localized: "Key", table: "<Room>")`.
  Add entries with `tools/room_strings.py` (supports plurals).
  For text that must not be translated use `Text(verbatim:)`.
  `LocalizationCatalogTests` enforces this.
- Visual check without Screen Recording rights: `tools/snap.sh <room> out.png
  [delay] [derived-data]` launches the Debug build on that room and writes a
  PNG of the window (the translucent sidebar comes out blank, that is expected).
- Visual language: native macOS, quiet. What is kept is drawn in gray tones,
  what can be reclaimed in color. Room tint from `VracRoom.tint`.
  No emoji in the interface.

## Architecture and task routing

- Scanning and rescans: `Radix/Services/ScanEngine.swift`,
  `ScanCoordinator.swift`, and `IncrementalScanService.swift`
- Tree and indexing: `Radix/Models/FileTreeStore.swift`
- App coordination: `Radix/ViewModels/AppModel.swift`; keep feature state and
  behavior in the dedicated owners below
- Navigation, focus, and selection: `Radix/ViewModels/WorkspaceNavigationModel.swift`
- Sidebar targets: `Radix/ViewModels/SidebarModel.swift`; scan caching and
  target restoration: `Radix/ViewModels/SidebarScanCacheController.swift`
- Modal presentation: `Radix/ViewModels/AppPresentationCoordinator.swift`
- Archive I/O: `Radix/Services/ScanArchiveService.swift`; operation progress
  and cancellation: `Radix/ViewModels/ArchiveWorkflowCoordinator.swift`
- Comparison calculations: `Radix/Services/ScanComparisonService.swift`;
  setup and preview state: `Radix/ViewModels/ComparisonFlowController.swift`;
  results browsing: `Radix/ViewModels/ScanComparisonBrowserModel.swift`
- Trash and discard-pile workflow: `Radix/ViewModels/TrashFlowController.swift`;
  safety rules: `Radix/Models/TrashSafetyPolicy.swift`
- File-browser search and sorting: `Radix/Services/FileBrowserModel.swift`
  and the adjacent `FileBrowser*` services
- Sunburst or treemap layout: the corresponding geometry/chart model in
  `Radix/Services/`; layout requests: `ChartLayoutRequestCoordinator.swift`
- Quick Look sessions: `Radix/ViewModels/AppQuickLookController.swift`;
  SwiftUI presentation: `Radix/Features/Workspace/WorkspaceQuickLookPreview.swift`;
  shared live-path validation: `Radix/Services/FileActionValidation.swift`
- Feature UI: `Radix/Features/`; reusable UI: `Radix/Shared/`;
  menu commands: `Radix/App/RadixCommands.swift`
- Swift Testing core and integration tests: `RadixCoreTests/`

`Package.swift` defines the non-UI `RadixCore` target. When adding or moving a
non-UI Swift file, update its explicit source list. The Xcode project builds
the complete app.

## Change guidelines

- Add new user-facing text to the appropriate `.xcstrings` catalog for every
  supported locale: `en`, `de`, `es`, `fr`, `it`, `ru`, and `zh-Hans`.
- Avoid new dependencies unless clearly justified. `RadixCore` has none.
- Sparkle is managed through Xcode Swift Package Manager; never vendor it.
- Use current documentation for version-sensitive Apple or external APIs.
- Prefer SwiftUI for UI. Use AppKit when it provides a simpler or more reliable implementation of required macOS behavior, or when measurements justify it for performance.
- Scanning must remain safe and responsive. Modifying or removing scanned files requires explicit user action.

## Validation

Choose validation based on the change:

- Production code, app resources, or build configuration: run the core
  tests and build the complete app.
- Test-only changes: run the affected tests. Run the full core suite
  when changing shared fixtures or test infrastructure.
- UI changes that affect interactions, navigation, focus, selection, or accessibility: manually exercise the affected behavior using this checkout’s exact Debug bundle.
- Static UI changes, such as editing text or removing an informational section, do not require a manual UI check unless they also affect behavior.
- Documentation-only changes: verify changed paths and commands and
  check the diff for formatting errors. Builds and tests are not required.
- Performance changes: run relevant benchmarks when practical.

Core test command:

    swift test

App build command:

    xcodebuild -project Radix.xcodeproj -scheme Radix \
      -configuration Debug -destination 'platform=macOS' \
      -derivedDataPath .build/xcode-derived-data build

For routine manual testing with Computer Use:

- Stop any other running Radix instances, then launch this checkout's exact
  Debug bundle:

      open -n .build/xcode-derived-data/Build/Products/Debug/Radix.app

- Use the full absolute path to that bundle for every Computer Use `app`
  argument. Require exactly one running Radix instance before testing; the
  `open -n` command deliberately starts a new instance.
- Never target the app as `Radix` or `com.colinkim.Radix`. Installed, archived,
  release, and DerivedData builds share that identity, so generic lookup can
  launch the wrong copy, including `/Applications/Radix.app`.

When the test specifically requires LLDB, scheme launch arguments, sanitizers,
or other Xcode diagnostics, start the shared scheme from the command line:

    xed -b Radix.xcodeproj
    xcrun xcdebug -s Radix -B -b

`xcdebug -B` performs the scheme's Build and Run action and attaches Xcode's
debugger; the `-b` options leave Xcode in the background.

## Simplicity and Code Economy

- Prefer the smallest coherent implementation that preserves correctness, clarity, and performance.
- Consolidate mechanisms that enforce the same invariant, not those with merely similar shapes.
- Before finishing, review the diff and touched code for redundant state, branches, abstractions, repeated work, duplicate tests, and opportunities to simplify data flow.
- In performance-sensitive paths, look for repeated traversal, allocation, I/O, or main-actor work. Measure meaningful performance changes when practical.
