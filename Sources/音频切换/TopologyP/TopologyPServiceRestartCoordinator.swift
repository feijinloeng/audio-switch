#if SWIFT_PACKAGE
import Foundation

/// Development-only service-restart integration for topology P. It owns no
/// realtime object and runs only on the control plane: stale route resources
/// are forgotten before route state reports that muted capture control was
/// lost. The Release composition root must not construct this until the
/// topology-P approval gate is accepted.
actor TopologyPServiceRestartCoordinator {
    private let hal: CoreAudioHAL
    private let transactions: AudioRouteTransactionExecutor
    private let routes: RouteCoordinator
    private var handledEpoch: UInt64

    init(
        hal: CoreAudioHAL,
        transactions: AudioRouteTransactionExecutor,
        routes: RouteCoordinator
    ) {
        self.hal = hal
        self.transactions = transactions
        self.routes = routes
        handledEpoch = hal.serviceEpoch
    }

    /// Installs the bridge after construction so the discovery callback never
    /// captures a partially initialized coordinator. Output discovery invokes
    /// this before its registry refresh on the serial HAL control plane.
    func beginObserving(_ discovery: OutputDeviceDiscovery) {
        let hal = hal
        discovery.onEvent = { [weak self, weak hal] event in
            guard event == .serviceRestarted, let hal else { return }
            let newEpoch = hal.serviceEpoch
            Task {
                await self?.handleServiceRestart(newHALEpoch: newEpoch)
            }
        }
    }

    func handleServiceRestart(newHALEpoch: UInt64) async {
        guard newHALEpoch > handledEpoch else { return }
        handledEpoch = newHALEpoch
        await transactions.invalidateAllForCoreAudioServiceRestart()
        await routes.handleServiceRestart(newHALEpoch: newHALEpoch)
    }
}
#endif
