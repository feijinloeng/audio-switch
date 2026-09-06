import AudioToolbox
import Foundation

extension AudioDeviceID {

    // MARK: - 音量检测

    /// 检查设备是否支持 CoreAudio 音量控制。
    func hasOutputVolumeControl() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(self, &address) else { return false }
        var settable: DarwinBoolean = false
        let err = AudioObjectIsPropertySettable(self, &address, &settable)
        return err == noErr && settable.boolValue
    }

    // MARK: - 读取音量

    /// 读取设备音量（0.0 ~ 1.0）。
    /// 按优先级尝试多个策略：
    /// 1. VirtualMainVolume（系统音量滑块使用的 selector）
    /// 2. VolumeScalar 主通道
    /// 3. VolumeScalar 左声道
    func readOutputVolumeScalar() -> Float {
        // 策略 1: VirtualMainVolume（推荐）
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(self, &address) {
            var volume: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(self, &address, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }

        // 策略 2: VolumeScalar 主通道
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(self, &address) {
            var volume: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(self, &address, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }

        // 策略 3: VolumeScalar 左声道
        address.mElement = 1
        if AudioObjectHasProperty(self, &address) {
            var volume: Float32 = 1.0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(self, &address, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }

        return 1.0
    }

    // MARK: - 设置音量

    /// 设置设备音量（0.0 ~ 1.0）。
    /// 优先使用 VirtualMainVolume；部分 USB/蓝牙设备只暴露主通道或
    /// 左右声道 VolumeScalar，因此继续尝试这些标准 Core Audio 属性。
    func setOutputVolumeScalar(_ volume: Float) -> Bool {
        let clampedVolume = Swift.max(0.0, Swift.min(1.0, volume))
        let addresses = [
            AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: 1
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: 2
            ),
        ]
        var didSetVolume = false
        for var address in addresses where AudioObjectHasProperty(self, &address) {
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(self, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            var volumeValue: Float32 = clampedVolume
            let size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(self, &address, 0, nil, size, &volumeValue) == noErr {
                didSetVolume = true
                if address.mSelector == kAudioHardwareServiceDeviceProperty_VirtualMainVolume
                    || address.mElement == kAudioObjectPropertyElementMain {
                    return true
                }
            }
        }
        return didSetVolume
    }

    // MARK: - 静音

    func readMuteState() -> Bool {
        for var address in outputMuteAddresses() where AudioObjectHasProperty(self, &address) {
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(self, &address, 0, nil, &size, &muted) == noErr {
                return muted != 0
            }
        }
        return false
    }

    func setMuteState(_ muted: Bool) -> Bool {
        var didSetMute = false
        for var address in outputMuteAddresses() where AudioObjectHasProperty(self, &address) {
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(self, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            var value: UInt32 = muted ? 1 : 0
            let size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectSetPropertyData(self, &address, 0, nil, size, &value) == noErr {
                didSetMute = true
                if address.mElement == kAudioObjectPropertyElementMain {
                    return true
                }
            }
        }
        return didSetMute
    }

    private func outputMuteAddresses() -> [AudioObjectPropertyAddress] {
        [
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: 1
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: 2
            ),
        ]
    }
}
