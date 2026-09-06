import AudioToolbox
import Foundation
import os

private let audioPropertyLogger = Logger(subsystem: "com.mankeipun.yinpinqiehuan", category: "AudioProperty")

extension AudioObjectID {

    // MARK: - 设备属性

    static func allAudioDevices() -> [AudioDeviceID] {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let sizeStatus = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard sizeStatus == noErr else {
            audioPropertyLogger.error("allAudioDevices: failed to get property data size: \(Int32(sizeStatus))")
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
        guard status == noErr else {
            audioPropertyLogger.error("allAudioDevices: failed to get property data: \(Int32(status))")
            return []
        }
        return devices
    }

    static func defaultOutputDevice() -> AudioDeviceID {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr else {
            audioPropertyLogger.error("defaultOutputDevice: failed to get property data: \(Int32(status))")
            return kAudioObjectUnknown
        }
        return id
    }

    // MARK: - 进程对象属性 (macOS 14+)

    /// 获取系统中所有已注册的音频进程对象。
    /// 使用 kAudioHardwarePropertyProcessObjectList 查询系统对象。
    static func readProcessList() -> [AudioObjectID] {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard sizeStatus == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &processes
        )
        guard status == noErr else { return [] }
        return processes
    }

    /// 读取音频进程对象的 PID。
    var processPID: pid_t? {
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &pid)
        return status == noErr ? pid : nil
    }

    /// 读取音频进程是否正在运行。
    var processIsRunning: Bool? {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &running)
        return status == noErr ? running != 0 : nil
    }

    /// 读取音频进程当前是否有输出 IO；用于排除只在录音的应用。
    var processIsRunningOutput: Bool? {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &running)
        return status == noErr ? running != 0 : nil
    }

    /// 读取音频进程的 Bundle ID。
    var processBundleID: String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        var bundleID: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &bundleID) { ptr in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfStr = bundleID?.takeRetainedValue() else { return nil }
        return cfStr as String
    }
}
