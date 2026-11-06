import AudioToolbox
import Foundation
import os

private let deviceInfoLogger = Logger(subsystem: "com.mankeipun.yinpinqiehuan", category: "DeviceInfo")

extension AudioDeviceID {
    func readDeviceName() -> String {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let name = name?.takeRetainedValue() else {
            deviceInfoLogger.error("readDeviceName(\(self)): failed with status \(Int32(status))")
            return "Unknown Device"
        }
        return name as String
    }

    func readDeviceUID() -> String {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let uid = uid?.takeRetainedValue() else {
            deviceInfoLogger.error("readDeviceUID(\(self)): failed with status \(Int32(status))")
            return ""
        }
        return uid as String
    }

    func readTransportType() -> TransportType {
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &type) == noErr else {
            return .unknown
        }
        return TransportType(rawValue: type) ?? .unknown
    }

    func isAlive() -> Bool {
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &alive) == noErr else {
            return false
        }
        return alive != 0
    }

    var isValid: Bool { self != kAudioObjectUnknown && isAlive() }

    func isDeviceHidden() -> Bool {
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &hidden) == noErr else {
            return false
        }
        return hidden != 0
    }

}

enum TransportType: UInt32 {
    case builtIn = 0x6275696C
    case bluetooth = 0x626c7565
    case bluetoothLE = 0x626c6565
    case airPlay = 0x61697270
    case usb = 0x75736220
    case hdmi = 0x68646d69
    case displayPort = 0x64706f72
    case thunderbolt = 0x74687562
    case fireWire = 0x66697265
    case pci = 0x70636920
    case aggregate = 0x61676772
    case unknown = 0

    var iconName: String {
        switch self {
        case .builtIn: return "macbook"
        case .bluetooth, .bluetoothLE: return "airpods.pro"
        case .airPlay: return "airplayaudio"
        case .usb: return "cable.connector"
        case .hdmi, .displayPort: return "display"
        case .thunderbolt: return "bolt.circle"
        case .aggregate: return "square.stack.3d.up"
        default: return "speaker.wave.2"
        }
    }
}
