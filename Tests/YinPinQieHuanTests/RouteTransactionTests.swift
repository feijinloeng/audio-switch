import XCTest
@testable import YinPinQieHuan

private actor PausingRouteBackend: RouteTransitionBackend {
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private(set) var rolledBack: [UUID] = []
    private(set) var committed: [UUID] = []

    func prepare(_ request: ManagedRouteRequest) async throws -> PreparedManagedRoute {
        await withCheckedContinuation { continuation in
            continuations[request.requestID] = continuation
        }
        return PreparedManagedRoute(requestID: request.requestID, opaqueID: UUID())
    }

    func commit(_ prepared: PreparedManagedRoute) async throws {
        committed.append(prepared.requestID)
    }

    func rollback(_ prepared: PreparedManagedRoute) async {
        rolledBack.append(prepared.requestID)
    }

    func isPreparing(_ requestID: UUID) -> Bool { continuations[requestID] != nil }
    func resume(_ requestID: UUID) { continuations.removeValue(forKey: requestID)?.resume() }
}

final class RouteTransactionTests: XCTestCase {
    func testNewerRouteCancelsAndRollsBackPreparedOlderRoute() async {
        let backend = PausingRouteBackend()
        let executor = RouteTransactionExecutor(backend: backend)
        let identity = AppIdentity(bundleID: "com.example.player")!
        let firstID = UUID()
        let secondID = UUID()

        let first = Task {
            await executor.execute(identity: identity, requestID: firstID, desired: .device(uid: "A"))
        }
        await waitUntil { await backend.isPreparing(firstID) }
        let second = Task {
            await executor.execute(identity: identity, requestID: secondID, desired: .device(uid: "B"))
        }
        await waitUntil { await backend.isPreparing(secondID) }

        await backend.resume(firstID)
        await backend.resume(secondID)

        let firstOutcome = await first.value
        let secondOutcome = await second.value
        let rolledBack = await backend.rolledBack
        let committed = await backend.committed
        XCTAssertEqual(firstOutcome, .cancelled)
        XCTAssertEqual(secondOutcome, .committed)
        XCTAssertEqual(rolledBack, [firstID])
        XCTAssertEqual(committed, [secondID])
    }

    private func waitUntil(_ predicate: @escaping () async -> Bool) async {
        for _ in 0 ..< 100 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("condition timed out")
    }
}
