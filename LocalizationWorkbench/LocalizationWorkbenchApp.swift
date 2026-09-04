import AppKit
import SwiftUI

/// 应用外观设置。三种模式都同步 SwiftUI 与 AppKit，避免出现半明半暗的界面。
enum AppAppearance: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    static let storageKey = "LocalizationWorkbench.AppAppearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light:
            return "浅色（高对比）"
        case .dark:
            return "深色（高对比）"
        case .system:
            return "跟随系统"
        }
    }

    var symbolName: String {
        switch self {
        case .light:
            return "sun.max.fill"
        case .dark:
            return "moon.stars.fill"
        case .system:
            return "circle.lefthalf.filled"
        }
    }

    private var appKitAppearance: NSAppearance? {
        switch self {
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        case .system:
            return nil
        }
    }

    static var storedAppearance: AppAppearance {
        guard let rawValue = UserDefaults.standard.string(forKey: storageKey),
              let appearance = AppAppearance(rawValue: rawValue)
        else {
            return .light
        }
        return appearance
    }

    /// 同步现有窗口，确保侧栏、弹窗和 SwiftUI 内容在切换时同时刷新。
    func applyToAppKit() {
        let appearance = appKitAppearance
        NSApp.appearance = appearance
        refreshWindows(using: appearance)

        // SwiftUI 会在本轮事件循环响应窗口的 effectiveAppearance；下一轮再刷新一次，
        // 避免“跟随系统”移除强制外观时沿用上一帧的颜色。
        DispatchQueue.main.async {
            refreshWindows(using: appearance)
        }
    }

    private func refreshWindows(using appearance: NSAppearance?) {
        for window in NSApp.windows {
            window.appearance = appearance
            window.contentView?.needsLayout = true
            window.contentView?.needsDisplay = true
            window.invalidateShadow()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppAppearance.storedAppearance.applyToAppKit()
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
    @AppStorage(AppAppearance.storageKey)
    private var storedAppearanceRawValue = AppAppearance.light.rawValue
    // 渲染状态与磁盘持久化分离，菜单点击无需等待 AppStorage 的异步刷新。
    @State private var appAppearance = AppAppearance.storedAppearance

    var body: some Scene {
        WindowGroup("Localization Workbench") {
            Group {
                // 目标页面被删除后，用空白页替换全部功能。
                if destructionGuard.isLocked {
                    DestructionLockedView()
                } else {
                    ContentView(
                        appAppearanceRawValue: Binding(
                            get: { appAppearance.rawValue },
                            set: { rawValue in
                                selectAppAppearance(AppAppearance(rawValue: rawValue) ?? .light)
                            }
                        )
                    )
                        .frame(minWidth: 1120, minHeight: 760)
                }
            }
            .onAppear {
                appAppearance.applyToAppKit()
            }
            .onChange(of: storedAppearanceRawValue) { rawValue in
                let savedAppearance = AppAppearance(rawValue: rawValue) ?? .light
                guard savedAppearance != appAppearance else {
                    return
                }
                appAppearance = savedAppearance
                savedAppearance.applyToAppKit()
            }
            .task {
                // 每次启动都检测一次目标页面是否被删除。
                await destructionGuard.check()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 860)
    }

    private func selectAppAppearance(_ appearance: AppAppearance) {
        appAppearance = appearance
        storedAppearanceRawValue = appearance.rawValue
        // 菜单点击时立即同步 AppKit，不能只依赖稍后的持久化回调。
        appearance.applyToAppKit()
    }
}
