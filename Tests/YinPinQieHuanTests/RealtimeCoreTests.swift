import RealtimeCore
import XCTest

final class RealtimeCoreTests: XCTestCase {
    func testRingBufferRejectsInvalidCapacityAndWrapsWithoutOverflow() {
        XCTAssertNil(ypq_ring_buffer_create(0))
        XCTAssertNil(ypq_ring_buffer_create(3))
        guard let buffer = ypq_ring_buffer_create(8) else { return XCTFail("create") }
        defer { ypq_ring_buffer_destroy(buffer) }

        var input = (0 ..< 16).map(Float.init)
        XCTAssertEqual(ypq_ring_buffer_write(buffer, &input, 8), 8)
        XCTAssertEqual(ypq_ring_buffer_available_to_write(buffer), 0)
        XCTAssertEqual(ypq_ring_buffer_write(buffer, &input, 1), 0)

        var firstRead = [Float](repeating: 0, count: 8)
        XCTAssertEqual(ypq_ring_buffer_read(buffer, &firstRead, 4), 4)
        XCTAssertEqual(Array(firstRead.prefix(8)), Array(input.prefix(8)))
        XCTAssertEqual(ypq_ring_buffer_write(buffer, &input, 4), 4)
        XCTAssertEqual(ypq_ring_buffer_available_to_read(buffer), 8)
    }

    func testCallbackGateClosesOnlyAfterAdmittedCallbackLeaves() {
        guard let gate = ypq_callback_gate_create() else { return XCTFail("create") }
        defer { ypq_callback_gate_destroy(gate) }
        XCTAssertTrue(ypq_callback_gate_try_enter(gate))
        XCTAssertFalse(ypq_callback_gate_try_enter(gate))
        ypq_callback_gate_leave(gate, 42)
        XCTAssertTrue(ypq_callback_gate_has_idle_acknowledgement(gate, 42))
        XCTAssertTrue(ypq_callback_gate_try_enter(gate))
        XCTAssertTrue(ypq_callback_gate_begin_closing(gate))
        XCTAssertFalse(ypq_callback_gate_is_quiescent(gate))
        ypq_callback_gate_leave(gate, 43)
        XCTAssertTrue(ypq_callback_gate_is_quiescent(gate))
        XCTAssertEqual(ypq_callback_gate_last_ack_generation(gate), 43)
        XCTAssertTrue(ypq_callback_gate_finish_closing(gate))
        XCTAssertFalse(ypq_callback_gate_try_enter(gate))
    }

    func testMuteUsesContinuousGainRampInsteadOfHardZero() {
        guard let binding = ypq_route_binding_create(2_048) else { return XCTFail("binding") }
        defer { ypq_route_binding_destroy(binding) }
        var bindings: [OpaquePointer?] = [binding]
        guard let session = ypq_device_render_session_create(
            &bindings,
            1,
            2_048,
            256,
            48_000,
            512,
            1
        ) else { return XCTFail("session") }
        defer { ypq_device_render_session_destroy(session) }

        let input = [Float](repeating: 0.5, count: 2_048 * 2)
        input.withUnsafeBufferPointer {
            XCTAssertEqual(ypq_route_binding_write(binding, $0.baseAddress, 2_048), 2_048)
        }
        var warmup = [Float](repeating: 0, count: 256 * 2)
        ypq_device_render_session_render(session, &warmup, 256)

        ypq_route_binding_publish_controls(binding, 1, true)
        var mutedTransition = [Float](repeating: 0, count: 256 * 2)
        ypq_device_render_session_render(session, &mutedTransition, 256)
        let first = abs(mutedTransition[0])
        let last = abs(mutedTransition[mutedTransition.count - 2])
        XCTAssertGreaterThan(first, 0.05)
        XCTAssertGreaterThan(last, 0)
        XCTAssertLessThan(last, first)
    }
}
