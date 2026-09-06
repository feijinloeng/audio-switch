import CryptoKit
import Foundation

/// The UDP payload used by the Mac host and the iPhone companion. Each packet
/// contains exactly 5 ms of 48 kHz, stereo, signed 16-bit PCM (240 frames).
/// The header is authenticated before a packet can enter the jitter buffer.
enum PanoramaWireProtocolError: Error, Equatable, Sendable {
    case unsupportedVersion
    case unsupportedMessageType
    case invalidPacketSize
    case invalidPayloadSize(actual: Int)
    case invalidAuthenticationTag
    case sessionMismatch
    case invalidFrameHeader
    case frameTooLarge(actual: Int)
}

enum PanoramaControlMessageType: UInt8, Sendable {
    case pairingRequest = 1
    case pairingResponse = 2
}

struct PanoramaControlFrame: Equatable, Sendable {
    static let version: UInt8 = 1
    static let maximumPayloadByteCount = 16 * 1_024
    private static let magic: [UInt8] = [0x59, 0x50, 0x43, 0x46] // YPCF
    private static let headerByteCount = 10

    let type: PanoramaControlMessageType
    let payload: Data

    func encoded() throws -> Data {
        guard payload.count <= Self.maximumPayloadByteCount else {
            throw PanoramaWireProtocolError.frameTooLarge(actual: payload.count)
        }
        var data = Data(Self.magic)
        data.append(Self.version)
        data.append(type.rawValue)
        data.appendBigEndian(UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func json<T: Encodable>(_ value: T, type: PanoramaControlMessageType) throws -> Data {
        try PanoramaControlFrame(type: type, payload: JSONEncoder().encode(value)).encoded()
    }

    func decodeJSON<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }

    struct Decoder: Sendable {
        private var buffer = Data()

        mutating func append(_ bytes: Data) throws -> [PanoramaControlFrame] {
            buffer.append(bytes)
            var frames: [PanoramaControlFrame] = []
            while buffer.count >= PanoramaControlFrame.headerByteCount {
                guard Array(buffer.prefix(4)) == PanoramaControlFrame.magic else {
                    throw PanoramaWireProtocolError.invalidFrameHeader
                }
                let versionIndex = buffer.index(buffer.startIndex, offsetBy: 4)
                guard buffer[versionIndex] == PanoramaControlFrame.version else {
                    throw PanoramaWireProtocolError.unsupportedVersion
                }
                let typeIndex = buffer.index(buffer.startIndex, offsetBy: 5)
                guard let type = PanoramaControlMessageType(rawValue: buffer[typeIndex]) else {
                    throw PanoramaWireProtocolError.unsupportedMessageType
                }
                let payloadLength = Int(buffer.readBigEndianUInt32(at: 6))
                guard payloadLength <= PanoramaControlFrame.maximumPayloadByteCount else {
                    throw PanoramaWireProtocolError.frameTooLarge(actual: payloadLength)
                }
                let frameLength = PanoramaControlFrame.headerByteCount + payloadLength
                guard buffer.count >= frameLength else { break }
                let payloadStart = buffer.index(
                    buffer.startIndex,
                    offsetBy: PanoramaControlFrame.headerByteCount
                )
                let payloadEnd = buffer.index(buffer.startIndex, offsetBy: frameLength)
                frames.append(
                    PanoramaControlFrame(
                        type: type,
                        payload: Data(buffer[payloadStart ..< payloadEnd])
                    )
                )
                buffer.removeFirst(frameLength)
            }
            return frames
        }
    }
}

enum PanoramaDatagramType: UInt8, Sendable {
    case audio = 0xA1
    case playoutControl = 0xA2
    case registration = 0xA3
}

enum CompanionRecoveryEvent: Equatable, Sendable {
    case interruptionEnded(shouldResume: Bool)
    case routeChanged
    case engineConfigurationChanged
    case udpConnectionFailed
}

enum CompanionRecoveryAction: Equatable, Sendable {
    case none
    case reactivateAudio
    case tearDownAndReconnect
}

enum CompanionRecoveryPolicy {
    static func action(for event: CompanionRecoveryEvent) -> CompanionRecoveryAction {
        switch event {
        case let .interruptionEnded(shouldResume):
            shouldResume ? .reactivateAudio : .none
        case .routeChanged, .engineConfigurationChanged:
            .reactivateAudio
        case .udpConnectionFailed:
            .tearDownAndReconnect
        }
    }
}

struct PanoramaSessionKey: Equatable, Sendable {
    let data: Data

    init?(data: Data) {
        guard data.count >= 16 else { return nil }
        self.data = data
    }
}

struct PanoramaPairingControlRequest: Codable, Equatable, Sendable {
    static let protocolVersion = 3

    let protocolVersion: Int
    let deviceName: String
    let outputName: String
    let outputVolume: Float
    let clientEphemeralPublicKey: Data
    let clientNonce: Data

    init(
        protocolVersion: Int,
        deviceName: String,
        outputName: String,
        outputVolume: Float = 1,
        clientEphemeralPublicKey: Data,
        clientNonce: Data
    ) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.outputName = outputName
        self.outputVolume = Self.clamped(outputVolume)
        self.clientEphemeralPublicKey = clientEphemeralPublicKey
        self.clientNonce = clientNonce
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case deviceName
        case outputName
        case outputVolume
        case clientEphemeralPublicKey
        case clientNonce
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
            deviceName: try container.decode(String.self, forKey: .deviceName),
            outputName: try container.decode(String.self, forKey: .outputName),
            outputVolume: try container.decodeIfPresent(Float.self, forKey: .outputVolume) ?? 1,
            clientEphemeralPublicKey: try container.decode(Data.self, forKey: .clientEphemeralPublicKey),
            clientNonce: try container.decode(Data.self, forKey: .clientNonce)
        )
    }

    private static func clamped(_ volume: Float) -> Float {
        volume.isFinite ? min(max(volume, 0), 1) : 1
    }
}

struct PanoramaPairingControlResponse: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let peerID: String
    let sessionID: UUID
    let udpPort: UInt16
    let identityPublicKey: Data
    let serverEphemeralPublicKey: Data
    let serverNonce: Data
    let sealedSessionKey: Data
    let signature: Data
}

/// First datagram sent by the companion after pairing. It binds the ephemeral
/// UDP flow to the peer and TLS-issued session key before the host emits audio.
struct PanoramaUDPRegistration: Codable, Equatable, Sendable {
    static let protocolVersion = 2

    let protocolVersion: Int
    let peerID: String
    let sessionID: UUID
    let outputName: String
    let outputVolume: Float
    let authenticationTag: Data

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case peerID
        case sessionID
        case outputName
        case outputVolume
        case authenticationTag
    }

    init(
        protocolVersion: Int = Self.protocolVersion,
        peerID: String,
        sessionID: UUID,
        outputName: String,
        outputVolume: Float = 1,
        authenticationTag: Data
    ) {
        self.protocolVersion = protocolVersion
        self.peerID = peerID
        self.sessionID = sessionID
        self.outputName = outputName
        self.outputVolume = Self.clamped(outputVolume)
        self.authenticationTag = authenticationTag
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
            peerID: try container.decode(String.self, forKey: .peerID),
            sessionID: try container.decode(UUID.self, forKey: .sessionID),
            outputName: try container.decode(String.self, forKey: .outputName),
            outputVolume: try container.decodeIfPresent(Float.self, forKey: .outputVolume) ?? 1,
            authenticationTag: try container.decode(Data.self, forKey: .authenticationTag)
        )
    }

    static func make(
        peerID: String,
        sessionID: UUID,
        outputName: String,
        outputVolume: Float = 1,
        key: PanoramaSessionKey
    ) -> PanoramaUDPRegistration {
        let volume = clamped(outputVolume)
        return PanoramaUDPRegistration(
            peerID: peerID,
            sessionID: sessionID,
            outputName: outputName,
            outputVolume: volume,
            authenticationTag: tag(
                peerID: peerID,
                sessionID: sessionID,
                outputName: outputName,
                outputVolume: volume,
                key: key
            )
        )
    }

    func isValid(for peerID: String, sessionID: UUID, key: PanoramaSessionKey) -> Bool {
        protocolVersion == Self.protocolVersion
            && self.peerID == peerID
            && self.sessionID == sessionID
            && authenticationTag.constantTimeEquals(Self.tag(
                peerID: peerID,
                sessionID: sessionID,
                outputName: outputName,
                outputVolume: outputVolume,
                key: key
            ))
    }

    private static func tag(
        peerID: String,
        sessionID: UUID,
        outputName: String,
        outputVolume: Float,
        key: PanoramaSessionKey
    ) -> Data {
        var payload = Data("yinpin-panorama-registration-v2".utf8)
        payload.append(PanoramaDatagramType.registration.rawValue)
        payload.appendBigEndian(UInt16(protocolVersion))
        payload.appendLengthPrefixedUTF8(peerID)
        Swift.withUnsafeBytes(of: sessionID.uuid) { payload.append(contentsOf: $0) }
        payload.appendLengthPrefixedUTF8(outputName)
        payload.appendBigEndian(canonicalVolume(outputVolume))
        let tag = HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key.data))
        return Data(tag.prefix(PanoramaAudioPacket.authenticationTagByteCount))
    }

    func encodedDatagram() throws -> Data {
        var data = Data([PanoramaDatagramType.registration.rawValue])
        data.append(try JSONEncoder().encode(self))
        return data
    }

    static func decodeDatagram(_ data: Data) throws -> PanoramaUDPRegistration {
        guard data.first == PanoramaDatagramType.registration.rawValue else {
            throw PanoramaWireProtocolError.unsupportedMessageType
        }
        return try JSONDecoder().decode(Self.self, from: data.dropFirst())
    }

    private static func canonicalVolume(_ volume: Float) -> UInt16 {
        UInt16((clamped(volume) * 1_000).rounded())
    }

    private static func clamped(_ volume: Float) -> Float {
        volume.isFinite ? min(max(volume, 0), 1) : 1
    }
}

/// Authenticated, Mac-authoritative control datagram for the companion
/// playout buffer. It deliberately uses the same session key as audio, but a
/// distinct domain prefix so it can never be confused with a registration or
/// with PCM packet bytes.
struct PanoramaCompanionPlayoutControl: Codable, Equatable, Sendable {
    static let protocolVersion = 1
    static let maximumStartupPackets = 800

    let protocolVersion: Int
    let sessionID: UUID
    let startupPackets: Int
    let authenticationTag: Data

    static func make(
        sessionID: UUID,
        startupPackets: Int,
        key: PanoramaSessionKey
    ) -> PanoramaCompanionPlayoutControl {
        let normalizedPackets = min(max(startupPackets, 1), maximumStartupPackets)
        return PanoramaCompanionPlayoutControl(
            protocolVersion: protocolVersion,
            sessionID: sessionID,
            startupPackets: normalizedPackets,
            authenticationTag: tag(sessionID: sessionID, startupPackets: normalizedPackets, key: key)
        )
    }

    func isValid(for expectedSessionID: UUID, key: PanoramaSessionKey) -> Bool {
        protocolVersion == Self.protocolVersion
            && sessionID == expectedSessionID
            && (1 ... Self.maximumStartupPackets).contains(startupPackets)
            && authenticationTag.constantTimeEquals(Self.tag(
                sessionID: sessionID,
                startupPackets: startupPackets,
                key: key
            ))
    }

    private static func tag(sessionID: UUID, startupPackets: Int, key: PanoramaSessionKey) -> Data {
        var payload = Data("yinpin-panorama-playout-v1".utf8)
        Swift.withUnsafeBytes(of: sessionID.uuid) { payload.append(contentsOf: $0) }
        var packets = UInt16(startupPackets).bigEndian
        Swift.withUnsafeBytes(of: &packets) { payload.append(contentsOf: $0) }
        let tag = HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key.data))
        return Data(tag.prefix(PanoramaAudioPacket.authenticationTagByteCount))
    }

    func encodedDatagram() throws -> Data {
        var data = Data([PanoramaDatagramType.playoutControl.rawValue])
        data.append(try JSONEncoder().encode(self))
        return data
    }

    static func decodeDatagram(_ data: Data) throws -> Self {
        guard data.first == PanoramaDatagramType.playoutControl.rawValue else {
            throw PanoramaWireProtocolError.unsupportedMessageType
        }
        return try JSONDecoder().decode(Self.self, from: data.dropFirst())
    }
}

enum PanoramaCompanionDelayPolicy {
    static let baseStartupPackets = 200
    static let maximumDelaySeconds: TimeInterval = 1

    static func delaySeconds(startupPackets: Int) -> TimeInterval {
        let delayPackets = max(0, startupPackets - baseStartupPackets)
        return min(
            TimeInterval(delayPackets) * 0.005,
            maximumDelaySeconds
        )
    }
}

struct PanoramaAudioPacket: Equatable, Sendable {
    static let version: UInt8 = 1
    static let sampleRate = 48_000
    static let channels = 2
    static let bitsPerSample = 16
    static let framesPerPacket = 240
    static let pcmByteCount = framesPerPacket * channels * (bitsPerSample / 8)
    static let authenticationTagByteCount = 16
    static let headerByteCount = 2 + 16 + 8 + 8
    static let encodedByteCount = headerByteCount + pcmByteCount + authenticationTagByteCount

    let sessionID: UUID
    let sequence: UInt64
    let masterFrame: UInt64
    let pcm: Data

    init(sessionID: UUID, sequence: UInt64, masterFrame: UInt64, pcm: Data) throws {
        guard pcm.count == Self.pcmByteCount else {
            throw PanoramaWireProtocolError.invalidPayloadSize(actual: pcm.count)
        }
        self.sessionID = sessionID
        self.sequence = sequence
        self.masterFrame = masterFrame
        self.pcm = pcm
    }

    func encoded(authenticatedWith key: PanoramaSessionKey) -> Data {
        var packet = Data(capacity: Self.encodedByteCount)
        packet.append(PanoramaDatagramType.audio.rawValue)
        packet.append(Self.version)
        withUnsafeBytes(of: sessionID.uuid) { packet.append(contentsOf: $0) }
        packet.appendBigEndian(sequence)
        packet.appendBigEndian(masterFrame)
        packet.append(pcm)
        let tag = HMAC<SHA256>.authenticationCode(for: packet, using: SymmetricKey(data: key.data))
        packet.append(contentsOf: tag.prefix(Self.authenticationTagByteCount))
        return packet
    }

    static func decode(
        _ data: Data,
        expectedSessionID: UUID,
        authenticatedWith key: PanoramaSessionKey
    ) throws -> PanoramaAudioPacket {
        guard data.count == encodedByteCount else {
            throw PanoramaWireProtocolError.invalidPacketSize
        }
        guard data[data.startIndex] == PanoramaDatagramType.audio.rawValue else {
            throw PanoramaWireProtocolError.unsupportedMessageType
        }
        guard data[data.index(after: data.startIndex)] == version else {
            throw PanoramaWireProtocolError.unsupportedVersion
        }

        let authenticatedEnd = data.index(data.endIndex, offsetBy: -authenticationTagByteCount)
        let authenticatedBytes = data[..<authenticatedEnd]
        let receivedTag = data[authenticatedEnd...]
        let expectedTag = HMAC<SHA256>.authenticationCode(
            for: authenticatedBytes,
            using: SymmetricKey(data: key.data)
        )
        guard Data(receivedTag).constantTimeEquals(
            Data(expectedTag.prefix(authenticationTagByteCount))
        ) else {
            throw PanoramaWireProtocolError.invalidAuthenticationTag
        }

        let sessionStart = data.index(data.startIndex, offsetBy: 2)
        let sessionEnd = data.index(sessionStart, offsetBy: 16)
        let sessionBytes = data[sessionStart..<sessionEnd]
        let sessionID = UUID(uuid: sessionBytes.withUnsafeBytes { rawBuffer in
            rawBuffer.load(as: uuid_t.self)
        })
        guard sessionID == expectedSessionID else {
            throw PanoramaWireProtocolError.sessionMismatch
        }

        let sequenceStart = sessionEnd
        let masterFrameStart = data.index(sequenceStart, offsetBy: 8)
        let payloadStart = data.index(masterFrameStart, offsetBy: 8)
        let sequence = data.readBigEndianUInt64(at: sequenceStart)
        let masterFrame = data.readBigEndianUInt64(at: masterFrameStart)
        return try PanoramaAudioPacket(
            sessionID: sessionID,
            sequence: sequence,
            masterFrame: masterFrame,
            pcm: Data(data[payloadStart..<authenticatedEnd])
        )
    }
}

/// A 64-packet sliding replay window. Small reordering is accepted once, while
/// duplicate, old, and cross-session packets are rejected before playout.
struct PanoramaReplayWindow: Sendable {
    private var latestSequence: UInt64?
    private var seenMask: UInt64 = 0

    mutating func accept(_ sequence: UInt64) -> Bool {
        guard let latestSequence else {
            self.latestSequence = sequence
            seenMask = 1
            return true
        }
        if sequence > latestSequence {
            let distance = sequence - latestSequence
            seenMask = distance >= 64 ? 1 : (seenMask << distance) | 1
            self.latestSequence = sequence
            return true
        }
        let distance = latestSequence - sequence
        guard distance < 64 else { return false }
        let bit = UInt64(1) << distance
        guard seenMask & bit == 0 else { return false }
        seenMask |= bit
        return true
    }
}

enum PanoramaJitterPlayout: Equatable, Sendable {
    case notReady
    case audio(Data)
    case interpolated(Data)
    case fadeOut
}

/// Bounded 5 ms packet jitter buffer. A single isolated loss repeats the
/// preceding PCM block; sustained loss enters fade-out without disturbing
/// other local panorama endpoints.
struct PanoramaJitterBuffer: Sendable {
    private let startupPackets: Int
    private let maximumPackets: Int
    private var packets: [UInt64: PanoramaAudioPacket] = [:]
    private var nextSequence: UInt64?
    private var lastPCM: Data?
    private var consecutiveMissing = 0
    private var started = false

    init(startupPackets: Int = 200, maximumPackets: Int = 260) {
        self.startupPackets = max(startupPackets, 1)
        self.maximumPackets = max(maximumPackets, startupPackets)
    }

    mutating func insert(_ packet: PanoramaAudioPacket) {
        if let nextSequence, packet.sequence < nextSequence { return }
        guard packets[packet.sequence] == nil else { return }
        packets[packet.sequence] = packet
        while packets.count > maximumPackets, let oldest = packets.keys.min() {
            packets.removeValue(forKey: oldest)
        }
    }

    mutating func dequeue() -> PanoramaJitterPlayout {
        guard started else {
            guard packets.count >= startupPackets, let earliest = packets.keys.min() else {
                return .notReady
            }
            nextSequence = earliest
            started = true
            return .notReady
        }
        guard let nextSequence else { return .notReady }
        if let packet = packets.removeValue(forKey: nextSequence) {
            self.nextSequence = nextSequence + 1
            lastPCM = packet.pcm
            consecutiveMissing = 0
            return .audio(packet.pcm)
        }
        consecutiveMissing += 1
        if consecutiveMissing == 1, let lastPCM {
            self.nextSequence = nextSequence + 1
            return .interpolated(lastPCM)
        }
        // Advancing during a sustained stall makes every later packet look
        // old, leaving the phone permanently silent. Re-enter startup
        // buffering and lock onto the earliest newly accumulated sequence.
        started = false
        self.nextSequence = nil
        lastPCM = nil
        consecutiveMissing = 0
        return .fadeOut
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    func readBigEndianUInt64(at index: Data.Index) -> UInt64 {
        let end = self.index(index, offsetBy: 8)
        return self[index..<end].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        let start = index(startIndex, offsetBy: offset)
        let end = index(start, offsetBy: 4)
        return self[start..<end].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func appendLengthPrefixedUTF8(_ value: String) {
        let bytes = Data(value.utf8)
        appendBigEndian(UInt32(bytes.count))
        append(bytes)
    }

    func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        return zip(self, other).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
