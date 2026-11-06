import AppKit
import AudioToolbox

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: TransportType
    let icon: NSImage?

    func hash(into hasher: inout Hasher) {
        hasher.combine(uid)
    }

    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        lhs.uid == rhs.uid
    }

    var isBuiltInOutput: Bool {
        if transport == .builtIn { return true }

        let normalizedUID = uid.lowercased()
        if normalizedUID.contains("builtin") || normalizedUID.contains("built-in") {
            return true
        }

        let normalizedName = name.lowercased()
        return normalizedName.contains("mac")
            && (normalizedName.contains("扬声器") || normalizedName.contains("speaker"))
    }
}

struct OutputDeviceConnectionOrder {
    private var externalUIDs: [String] = []

    mutating func ordered(_ devices: [AudioDevice]) -> [AudioDevice] {
        let builtInDevices = devices.filter(\.isBuiltInOutput)
        let externalDevices = devices.filter { !$0.isBuiltInOutput }
        // 设备 UID 来自系统发现，防御重复 UID 避免字典断言崩溃。
        let externalByUID = Dictionary(
            externalDevices.map { ($0.uid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        externalUIDs.removeAll { externalByUID[$0] == nil }
        for device in externalDevices where !externalUIDs.contains(device.uid) {
            externalUIDs.append(device.uid)
        }

        return builtInDevices + externalUIDs.compactMap { externalByUID[$0] }
    }
}

enum OutputVolumeDeviceResolver {
    static func device(
        configuredDeviceUID: String?,
        systemDefaultUID: String,
        devices: [AudioDevice]
    ) -> AudioDevice? {
        let targetUID = configuredDeviceUID ?? systemDefaultUID
        return devices.first { $0.uid == targetUID }
    }
}
