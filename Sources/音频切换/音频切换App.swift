import SwiftUI
import AppKit
import os
import UserNotifications

private let logger = Logger(subsystem: "com.mankeipun.yinpinqiehuan", category: "App")

enum WindowRestorationPolicy {
    /// 菜单栏应用没有主内容窗口；恢复旧窗口会意外重新打开设置页。
    static let shouldRestorePastWindows = false
}

// removed @main - see AppEntry.swift
struct 音频切换App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView(audioEngine: appDelegate.audioEngine)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
enum AboutPanelOptions {
    static let values: [NSApplication.AboutPanelOptionKey: Any] = [
        .applicationName: "音频切换",
        .credits: NSAttributedString(string: "智能音频控制，让每个应用的声音都恰到好处。")
    ]
}

enum ApplicationMenuFactory {
    static let title = "音频切换"

    static func make(target: AnyObject, aboutAction: Selector) -> NSMenu {
        let menu = NSMenu(title: title)
        let aboutItem = menu.addItem(
            withTitle: "关于 音频切换",
            action: aboutAction,
            keyEquivalent: ""
        )
        aboutItem.target = target
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: "退出 音频切换",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }

    static func makeMainMenu(target: AnyObject, aboutAction: Selector) -> NSMenu {
        let mainMenu = NSMenu(title: title)
        let appMenu = make(target: target, aboutAction: aboutAction)
        let appMenuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        return mainMenu
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let audioEngine: AudioEngineFacade
    let permission: AudioPermissionManager
    let settingsManager: SettingsManager
    var menuBarManager: MenuBarManager?

    override init() {
        let settings = SettingsManager()
        let perm = AudioPermissionManager()
        let engine = TopologyPAudioEngine(permission: perm, settingsManager: settings)
        self.audioEngine = AudioEngineFacade(backend: engine)
        self.permission = perm
        self.settingsManager = settings
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // This is a menu-bar utility, not a foreground window application.
        NSApp.setActivationPolicy(.accessory)
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        audioEngine.setOutputDeviceDisconnectHandler { [weak self] deviceName in
            self?.postOutputDeviceDisconnectNotification(deviceName: deviceName)
        }

        // 应用日志级别配置
        Log.currentLevel = settingsManager.appSettings.logLevel

        audioEngine.start()
        requestNotificationPermissionIfNeeded()

        let mgr = MenuBarManager(audioEngine: audioEngine)
        mgr.start(settingsManager: settingsManager)
        menuBarManager = mgr

        // 创建主菜单，让 Cmd+Q 退出项生效
        setupMainMenu()

        Log.info(logger, "音频切换 started")
    }

    private func setupMainMenu() {
        NSApplication.shared.mainMenu = ApplicationMenuFactory.makeMainMenu(
            target: self,
            aboutAction: #selector(showAboutPanel)
        )
    }

    @objc private func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(options: AboutPanelOptions.values)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func requestNotificationPermissionIfNeeded() {
        guard settingsManager.appSettings.showDeviceDisconnectAlerts else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let notificationSettings = await center.notificationSettings()
            guard notificationSettings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    private func postOutputDeviceDisconnectNotification(deviceName: String) {
        guard settingsManager.appSettings.showDeviceDisconnectAlerts else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let notificationSettings = await center.notificationSettings()
            guard settingsManager.appSettings.showDeviceDisconnectAlerts,
                  notificationSettings.authorizationStatus == .authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = "音频设备已断开"
            content.body = "“\(deviceName)”已从 Mac 断开。"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "output-disconnected-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
            } catch {
                Log.error(logger, "发送设备断开通知失败: \(error.localizedDescription)")
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreState(_ app: NSApplication) -> Bool {
        WindowRestorationPolicy.shouldRestorePastWindows
    }

    func applicationWillTerminate(_ notification: Notification) {
        settingsManager.flush()
        audioEngine.stop()
        menuBarManager?.stop()
    }

}
