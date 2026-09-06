import ServiceManagement

/// macOS 通过主应用登录项在设备开机并进入用户会话后自动启动图形应用。
@MainActor
enum StartupLaunchManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func apply(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
