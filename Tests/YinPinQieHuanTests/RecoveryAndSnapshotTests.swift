import XCTest
@testable import YinPinQieHuan

final class RecoveryAndSnapshotTests: XCTestCase {
    func testRenderSnapshotIsReplacedOnceBeforeBorrowedBindingRetirement() {
        let removed = UUID()
        let retained = UUID()
        var state = OutputRenderSnapshotState(renderedBindingTokens: [removed, retained])
        var replacementCount = 0

        let firstReplacement = state.replaceIfNeeded(
            removing: [removed],
            publishing: [retained]
        ) {
            replacementCount += 1
        }
        let duplicateReplacement = state.replaceIfNeeded(
            removing: [removed],
            publishing: [retained]
        ) {
            replacementCount += 1
        }

        XCTAssertTrue(firstReplacement)
        XCTAssertFalse(duplicateReplacement)
        XCTAssertEqual(replacementCount, 1)
        XCTAssertEqual(state.renderedBindingTokens, [retained])
    }

    func testFailedRenderSnapshotReplacementDoesNotPublishFalseReclamationProof() {
        enum ReplacementError: Error { case failed }

        let removed = UUID()
        let retained = UUID()
        var state = OutputRenderSnapshotState(renderedBindingTokens: [removed, retained])

        XCTAssertThrowsError(
            try state.replaceIfNeeded(removing: [removed], publishing: [retained]) {
                throw ReplacementError.failed
            }
        )
        XCTAssertEqual(state.renderedBindingTokens, [removed, retained])
    }

    func testHALServiceRestartFailsManagedRouteAndRepreparesNativeRoute() async {
        let coordinator = RouteCoordinator(initialHALEpoch: 7)
        let managedIdentity = AppIdentity(bundleID: "com.example.managed")!
        let nativeIdentity = AppIdentity(bundleID: "com.example.native")!
        let selection = DefaultOutputSelection(deviceUID: "default-output", generation: 4)

        _ = await coordinator.request(
            identity: managedIdentity,
            desired: .device(uid: "external-output"),
            settings: PerAppDSPSettings(volume: 0.5, muted: false),
            defaultSelection: selection
        )
        _ = await coordinator.request(
            identity: nativeIdentity,
            desired: .followSystemDefault,
            settings: PerAppDSPSettings(volume: 1, muted: false),
            defaultSelection: selection
        )

        await coordinator.handleServiceRestart(newHALEpoch: 8)

        let managedState = await coordinator.state(for: managedIdentity)
        let nativeState = await coordinator.state(for: nativeIdentity)
        XCTAssertEqual(managedState.failure, .captureControlLost)
        XCTAssertEqual(nativeState.phase, .preparingNative)
    }
}
