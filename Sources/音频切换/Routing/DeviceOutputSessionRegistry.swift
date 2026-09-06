import Foundation

/// Control-plane snapshot of a single physical output session. The concrete
/// AUHAL instance remains backend-owned, while this registry enforces the
/// topology invariant that a device has at most one session.
struct DeviceOutputSessionSnapshot: Equatable, Sendable {
    let deviceUID: String
    let boundInstances: Set<AppInstanceID>
}

actor DeviceOutputSessionRegistry {
    private var instancesByDeviceUID: [String: Set<AppInstanceID>] = [:]
    private var deviceUIDByInstance: [AppInstanceID: String] = [:]

    func bind(_ instances: Set<AppInstanceID>, to deviceUID: String) {
        guard !deviceUID.isEmpty else { return }
        for instance in instances {
            remove(instance)
            instancesByDeviceUID[deviceUID, default: []].insert(instance)
            deviceUIDByInstance[instance] = deviceUID
        }
    }

    func detach(_ instances: Set<AppInstanceID>) {
        for instance in instances {
            remove(instance)
        }
    }

    func snapshot(for deviceUID: String) -> DeviceOutputSessionSnapshot? {
        guard let instances = instancesByDeviceUID[deviceUID], !instances.isEmpty else { return nil }
        return DeviceOutputSessionSnapshot(deviceUID: deviceUID, boundInstances: instances)
    }

    func activeSessionCount() -> Int { instancesByDeviceUID.count }

    private func remove(_ instance: AppInstanceID) {
        guard let oldDeviceUID = deviceUIDByInstance.removeValue(forKey: instance) else { return }
        instancesByDeviceUID[oldDeviceUID]?.remove(instance)
        if instancesByDeviceUID[oldDeviceUID]?.isEmpty == true {
            instancesByDeviceUID.removeValue(forKey: oldDeviceUID)
        }
    }
}
