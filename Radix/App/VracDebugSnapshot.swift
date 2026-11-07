#if DEBUG
import AppKit

/// Debug-only window capture, so rooms can be checked visually without Screen Recording rights:
///     open -n Vrac.app --args -VracRoom cleanup -VracSnapshot /tmp/cleanup.png -VracSnapshotDelay 6
/// Writes the main window to PNG after the delay, then quits.
enum VracDebugSnapshot {
    static var initialRoom: VracRoom? {
        UserDefaults.standard.string(forKey: "VracRoom").flatMap(VracRoom.init(rawValue:))
    }

    @MainActor
    static func scheduleIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "VracSnapshot") else { return }
        let delay = UserDefaults.standard.object(forKey: "VracSnapshotDelay") as? Double ?? 5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                NSApp.terminate(nil)
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }
}
#endif
