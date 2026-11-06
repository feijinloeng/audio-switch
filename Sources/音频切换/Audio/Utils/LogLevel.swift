import Foundation
import os

// MARK: - 日志级别

/// 运行时可配置的日志级别。
/// 用于控制 Logger 输出的详细程度，不影响 Apple 系统日志级别。
enum LogLevel: Int, Codable, CaseIterable, Identifiable {
    case debug   = 0  // 所有日志（开发环境）
    case info    = 1  // 常规信息
    case warning = 2  // 仅警告和错误
    case error   = 3  // 仅错误
    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .debug: return "调试"
        case .info: return "信息"
        case .warning: return "警告"
        case .error: return "错误"
        }
    }
}

// MARK: - 运行时日志工具

/// 配合 os.Logger 使用，根据 AppSettings.logLevel 过滤日志。
/// 用法：`Log.info(logger, "消息")` / `Log.debug(logger, "调试信息")`
enum Log {
    private static let level = OSAllocatedUnfairLock(initialState: LogLevel.info)

    /// 全局日志级别。由 AppDelegate 在启动时从 AppSettings 读取设置。
    /// 读写通过系统不公平锁同步，因此后台音频/网络任务无需绕回主线程。
    static var currentLevel: LogLevel {
        get { level.withLock { $0 } }
        set { level.withLock { $0 = newValue } }
    }

    static func isEnabled(_ messageLevel: LogLevel, at configuredLevel: LogLevel) -> Bool {
        messageLevel.rawValue >= configuredLevel.rawValue
    }

    static func debug(_ logger: Logger, _ message: String) {
        guard isEnabled(.debug, at: currentLevel) else { return }
        logger.debug("\(message, privacy: .public)")
    }

    static func info(_ logger: Logger, _ message: String) {
        guard isEnabled(.info, at: currentLevel) else { return }
        logger.info("\(message, privacy: .public)")
    }

    static func warning(_ logger: Logger, _ message: String) {
        guard isEnabled(.warning, at: currentLevel) else { return }
        logger.warning("\(message, privacy: .public)")
    }

    static func error(_ logger: Logger, _ message: String) {
        guard isEnabled(.error, at: currentLevel) else { return }
        logger.error("\(message, privacy: .public)")
    }
}
