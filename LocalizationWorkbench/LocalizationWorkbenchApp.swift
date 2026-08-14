import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        clearSavedState()
    }

    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    private func clearSavedState() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return
        }

        let savedStateURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State/\(bundleIdentifier).savedState")
        try? FileManager.default.removeItem(at: savedStateURL)
    }
}

@main
struct LocalizationWorkbenchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var destructionGuard = DestructionGuard()

    var body: some Scene {
        WindowGroup("Localization Workbench") {
            Group {
                // 目标页面被删除后，用空白页替换全部功能。
                if destructionGuard.isLocked {
                    DestructionLockedView()
                } else {
                    ContentView()
                        .frame(minWidth: 1120, minHeight: 760)
                }
            }
            .task {
                // 每次启动都检测一次目标页面是否被删除。
                await destructionGuard.check()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 860)
    }
}
