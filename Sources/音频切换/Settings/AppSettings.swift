import Foundation

struct AppSettings: Codable, Equatable {
    var launchOnStartup: Bool = false
    var showDeviceDisconnectAlerts: Bool = true

    /// 日志级别（运行时过滤 Logger 输出）
    var logLevel: LogLevel = .info

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        launchOnStartup = try values.decodeIfPresent(Bool.self, forKey: .launchOnStartup)
            ?? values.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
            ?? launchOnStartup
        showDeviceDisconnectAlerts = try values.decodeIfPresent(Bool.self, forKey: .showDeviceDisconnectAlerts) ?? showDeviceDisconnectAlerts
        logLevel = try values.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? logLevel
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(launchOnStartup, forKey: .launchOnStartup)
        try values.encode(showDeviceDisconnectAlerts, forKey: .showDeviceDisconnectAlerts)
        try values.encode(logLevel, forKey: .logLevel)
    }

    private enum CodingKeys: String, CodingKey {
        case launchOnStartup
        case launchAtLogin
        case showDeviceDisconnectAlerts
        case logLevel
    }
}
