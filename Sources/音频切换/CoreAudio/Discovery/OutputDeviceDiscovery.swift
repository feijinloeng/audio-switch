import Foundation

/// Bridges HAL notifications into an output-only registry. All snapshot reads
/// and publications are serialized through the control-plane executor; a HAL
/// listener never changes route state directly.
final class OutputDeviceDiscovery: @unchecked Sendable {
    typealias SnapshotHandler = (HALOutputSnapshot, DefaultOutputSelection) -> Void
    typealias EventHandler = (CoreAudioHALEvent) -> Void

    private let hal: CoreAudioHAL
    private let registry: OutputDeviceRegistry
    private let executor: CoreAudioHALExecutor

    var onSnapshotPublished: SnapshotHandler?
    /// Delivered on the same serial control-plane executor as the subsequent
    /// registry refresh. Consumers can invalidate epoch-scoped route resources
    /// before observing the new device snapshot.
    var onEvent: EventHandler?

    init(
        hal: CoreAudioHAL,
        registry: OutputDeviceRegistry,
        executor: CoreAudioHALExecutor = CoreAudioHALExecutor()
    ) {
        self.hal = hal
        self.registry = registry
        self.executor = executor
    }

    func start() {
        hal.setEventHandler { [weak self] event in
            guard let self else { return }
            self.executor.async { [weak self] in
                guard let self else { return }
                self.onEvent?(event)
                self.refresh()
            }
        }
        refresh()
    }

    func stop() {
        hal.stopObserving()
    }

    func refresh() {
        let snapshot = hal.outputSnapshot()
        let selection = registry.replace(
            devices: snapshot.devices,
            defaultDeviceUID: snapshot.defaultDeviceUID
        )
        onSnapshotPublished?(snapshot, selection)
    }
}
