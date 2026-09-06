import Foundation

/// Keeps connection failures in a single localizable surface. The Chinese
/// strings live in Localizable.strings; additional languages can override the
/// same stable keys without changing pairing or playback behavior.
enum CompanionLocalizedMessage {
    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let format = NSLocalizedString(
            key,
            tableName: "Localizable",
            bundle: .main,
            value: key,
            comment: "Companion connection or playback failure"
        )
        return String(format: format, locale: .current, arguments: arguments)
    }
}
