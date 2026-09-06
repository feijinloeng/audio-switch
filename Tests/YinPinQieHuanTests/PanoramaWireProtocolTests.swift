import CryptoKit
import Foundation
import XCTest
@testable import YinPinQieHuan

final class PanoramaWireProtocolTests: XCTestCase {
    private let key = PanoramaSessionKey(data: Data(repeating: 0x5A, count: 32))!

    func testControlFrameReassemblesFragmentedTCPReads() throws {
        let request = PanoramaPairingControlRequest(
            protocolVersion: PanoramaPairingControlRequest.protocolVersion,
            deviceName: "iPhone",
            outputName: "Speaker",
            outputVolume: 0.75,
            clientEphemeralPublicKey: Data(repeating: 1, count: 32),
            clientNonce: Data(repeating: 2, count: 32)
        )
        let encoded = try PanoramaControlFrame.json(request, type: .pairingRequest)
        var decoder = PanoramaControlFrame.Decoder()

        XCTAssertTrue(try decoder.append(Data(encoded.prefix(3))).isEmpty)
        XCTAssertTrue(try decoder.append(Data(encoded.dropFirst(3).prefix(5))).isEmpty)
        let frames = try decoder.append(Data(encoded.dropFirst(8)))

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].type, .pairingRequest)
        XCTAssertEqual(try frames[0].decodeJSON(PanoramaPairingControlRequest.self), request)
    }

    func testControlFrameDecodesCoalescedTCPReads() throws {
        let first = try PanoramaControlFrame(type: .pairingRequest, payload: Data("one".utf8)).encoded()
        let second = try PanoramaControlFrame(type: .pairingResponse, payload: Data("two".utf8)).encoded()
        var decoder = PanoramaControlFrame.Decoder()
        let frames = try decoder.append(first + second)
        XCTAssertEqual(frames.map(\.type), [.pairingRequest, .pairingResponse])
        XCTAssertEqual(frames.map(\.payload), [Data("one".utf8), Data("two".utf8)])
    }

    func testControlFrameRejectsOversizedPayloadBeforeAllocation() throws {
        var header = Data([0x59, 0x50, 0x43, 0x46, PanoramaControlFrame.version, PanoramaControlMessageType.pairingRequest.rawValue])
        var size = UInt32(PanoramaControlFrame.maximumPayloadByteCount + 1).bigEndian
        withUnsafeBytes(of: &size) { header.append(contentsOf: $0) }
        var decoder = PanoramaControlFrame.Decoder()
        XCTAssertThrowsError(try decoder.append(header)) { error in
            XCTAssertEqual(
                error as? PanoramaWireProtocolError,
                .frameTooLarge(actual: PanoramaControlFrame.maximumPayloadByteCount + 1)
            )
        }
    }

    func testRegistrationAuthenticatesVolumeAndAllIdentityFields() throws {
        let sessionID = UUID()
        let registration = PanoramaUDPRegistration.make(
            peerID: "peer",
            sessionID: sessionID,
            outputName: "Speaker",
            outputVolume: 0.25,
            key: key
        )
        XCTAssertTrue(registration.isValid(for: "peer", sessionID: sessionID, key: key))

        let tampered = PanoramaUDPRegistration(
            peerID: registration.peerID,
            sessionID: registration.sessionID,
            outputName: registration.outputName,
            outputVolume: 0.9,
            authenticationTag: registration.authenticationTag
        )
        XCTAssertFalse(tampered.isValid(for: "peer", sessionID: sessionID, key: key))
    }

    func testDatagramTypeDispatchDoesNotInterpretAudioAsJSON() throws {
        let packet = try PanoramaAudioPacket(
            sessionID: UUID(),
            sequence: 1,
            masterFrame: 240,
            pcm: Data(repeating: 0, count: PanoramaAudioPacket.pcmByteCount)
        )
        let encoded = packet.encoded(authenticatedWith: key)
        XCTAssertEqual(encoded.first, PanoramaDatagramType.audio.rawValue)
        XCTAssertThrowsError(try PanoramaCompanionPlayoutControl.decodeDatagram(encoded))
    }

    func testSignedEphemeralPairingRoundTripAndTamperRejection() throws {
        let identity = PanoramaPairingIdentity(privateKey: Curve25519.Signing.PrivateKey())
        let handshake = PanoramaClientHandshake()
        let request = PanoramaPairingControlRequest(
            protocolVersion: PanoramaPairingControlRequest.protocolVersion,
            deviceName: "iPhone",
            outputName: "Speaker",
            outputVolume: 0.5,
            clientEphemeralPublicKey: handshake.privateKey.publicKey.rawRepresentation,
            clientNonce: handshake.nonce
        )
        let sessionID = UUID()
        let response = try PanoramaPairingSecurity.makeServerResponse(
            request: request,
            peerID: "peer",
            sessionID: sessionID,
            udpPort: 45_000,
            sessionKey: key,
            identity: identity
        )
        XCTAssertEqual(
            try PanoramaPairingSecurity.openServerResponse(
                response,
                request: request,
                handshake: handshake,
                expectedIdentityPublicKey: identity.publicKeyData
            ),
            key
        )

        var tamperedSignature = response.signature
        tamperedSignature[0] ^= 0xFF
        let tampered = PanoramaPairingControlResponse(
            protocolVersion: response.protocolVersion,
            peerID: response.peerID,
            sessionID: response.sessionID,
            udpPort: response.udpPort,
            identityPublicKey: response.identityPublicKey,
            serverEphemeralPublicKey: response.serverEphemeralPublicKey,
            serverNonce: response.serverNonce,
            sealedSessionKey: response.sealedSessionKey,
            signature: tamperedSignature
        )
        XCTAssertThrowsError(
            try PanoramaPairingSecurity.openServerResponse(
                tampered,
                request: request,
                handshake: handshake,
                expectedIdentityPublicKey: identity.publicKeyData
            )
        )
    }

    func testReplayWindowAcceptsReorderingOnceAndRejectsDuplicates() {
        var window = PanoramaReplayWindow()
        XCTAssertTrue(window.accept(100))
        XCTAssertTrue(window.accept(102))
        XCTAssertTrue(window.accept(101))
        XCTAssertFalse(window.accept(101))
        XCTAssertFalse(window.accept(1))
    }

    func testCompanionRecoveryPolicyCoversInterruptionBluetoothAndUDPFailure() {
        XCTAssertEqual(
            CompanionRecoveryPolicy.action(for: .interruptionEnded(shouldResume: true)),
            .reactivateAudio
        )
        XCTAssertEqual(
            CompanionRecoveryPolicy.action(for: .interruptionEnded(shouldResume: false)),
            .none
        )
        XCTAssertEqual(CompanionRecoveryPolicy.action(for: .routeChanged), .reactivateAudio)
        XCTAssertEqual(
            CompanionRecoveryPolicy.action(for: .engineConfigurationChanged),
            .reactivateAudio
        )
        XCTAssertEqual(
            CompanionRecoveryPolicy.action(for: .udpConnectionFailed),
            .tearDownAndReconnect
        )
    }

    func testPacketScheduleSkipsMissedDeadlinesWithoutCatchUpBurst() {
        let clock = ContinuousClock()
        let start = clock.now
        XCTAssertEqual(
            PanoramaPacketSchedule.nextDeadline(after: start, now: start),
            start.advanced(by: .milliseconds(5))
        )
        let late = start.advanced(by: .milliseconds(100))
        XCTAssertEqual(
            PanoramaPacketSchedule.nextDeadline(after: start, now: late),
            late.advanced(by: .milliseconds(5))
        )
    }

    func testJitterBufferRecoversAfterSustainedLoss() throws {
        var buffer = PanoramaJitterBuffer(startupPackets: 2, maximumPackets: 4)
        buffer.insert(try packet(sequence: 10))
        buffer.insert(try packet(sequence: 11))
        XCTAssertEqual(buffer.dequeue(), .notReady)
        guard case .audio = buffer.dequeue() else { return XCTFail("expected audio") }
        guard case .audio = buffer.dequeue() else { return XCTFail("expected audio") }
        guard case .interpolated = buffer.dequeue() else { return XCTFail("expected interpolation") }
        XCTAssertEqual(buffer.dequeue(), .fadeOut)
        buffer.insert(try packet(sequence: 20))
        buffer.insert(try packet(sequence: 21))
        XCTAssertEqual(buffer.dequeue(), .notReady)
        guard case .audio = buffer.dequeue() else { return XCTFail("expected recovered audio") }
    }

    private func packet(sequence: UInt64) throws -> PanoramaAudioPacket {
        try PanoramaAudioPacket(
            sessionID: UUID(),
            sequence: sequence,
            masterFrame: sequence * UInt64(PanoramaAudioPacket.framesPerPacket),
            pcm: Data(repeating: UInt8(truncatingIfNeeded: sequence), count: PanoramaAudioPacket.pcmByteCount)
        )
    }
}
