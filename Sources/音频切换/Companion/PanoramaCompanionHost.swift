import Foundation
import Network
import os
import Security

enum PanoramaSessionKeyGenerationError: LocalizedError, Equatable {
    case secureRandomUnavailable(OSStatus)
    case invalidGeneratedKey

    var errorDescription: String? {
        "无法建立安全会话，请稍后重试。"
    }
}

enum PanoramaSessionKeyGenerator {
    typealias SecureRandomBytes = (UnsafeMutableRawPointer, Int) -> OSStatus

    static let keyByteCount = 32

    static func make(
        secureRandomBytes: SecureRandomBytes = { pointer, count in
            SecRandomCopyBytes(kSecRandomDefault, count, pointer)
        }
    ) -> Result<PanoramaSessionKey, PanoramaSessionKeyGenerationError> {
        var keyData = Data(count: keyByteCount)
        let status = keyData.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else {
                return errSecAllocate
            }
            return secureRandomBytes(baseAddress, keyByteCount)
        }
        guard status == errSecSuccess else {
            return .failure(.secureRandomUnavailable(status))
        }
        guard let key = PanoramaSessionKey(data: keyData) else {
            return .failure(.invalidGeneratedKey)
        }
        return .success(key)
    }
}

/// Mac-side Bonjour/TLS discovery endpoint. It is advertised for the lifetime
/// of the app, while an iPhone explicitly confirms the Mac before requesting a
/// fresh authenticated audio session.
@MainActor
final class PanoramaCompanionHost {
    private static let tcpServiceType = "_yinpin-panorama._tcp"
    private let logger = Logger(subsystem: "com.mankeipun.yinpinqiehuan", category: "Companion")
    private let sessionKeyGenerator: () -> Result<PanoramaSessionKey, PanoramaSessionKeyGenerationError>
    private let pairingIdentity: PanoramaPairingIdentity?
    nonisolated let networkTransport = PanoramaNetworkTransport()

    private var tcpListener: NWListener?
    private var udpListener: NWListener?
    private var pairedSession: PairedSession?
    private(set) var lastError: String?
    var onEndpointStatusChanged: ((PanoramaCompanionEndpointStatus) -> Void)?

    init(
        sessionKeyGenerator: @escaping () -> Result<PanoramaSessionKey, PanoramaSessionKeyGenerationError> = {
            PanoramaSessionKeyGenerator.make()
        }
    ) {
        self.sessionKeyGenerator = sessionKeyGenerator
        pairingIdentity = try? PanoramaPairingIdentityStore.loadOrCreate()
    }

    var pairingFingerprint: String {
        pairingIdentity?.fingerprint ?? "身份不可用"
    }

    private struct PairedSession {
        let peerID: String
        let deviceName: String
        var outputName: String
        var outputVolume: Float
        let sessionID: UUID
        let key: PanoramaSessionKey
        var controlConnection: NWConnection?
        var udpConnection: NWConnection?
        var startupPackets: Int
    }

    func startAdvertising() {
        guard tcpListener == nil, udpListener == nil else { return }
        startUDPListener()
    }

    private func startTCPListener() {
        guard tcpListener == nil else { return }
        guard let pairingIdentity else {
            lastError = "无法读取本机配对身份"
            return
        }
        do {
            let listener = try NWListener(
                using: PanoramaPairingTLS.automaticParameters(),
                on: .any
            )
            listener.service = NWListener.Service(
                type: Self.tcpServiceType,
                txtRecord: NWTXTRecord([
                    "identity": pairingIdentity.publicKeyData.base64EncodedString(),
                    "fingerprint": pairingIdentity.fingerprint,
                    "protocol": String(PanoramaPairingControlRequest.protocolVersion),
                ])
            )
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                Task { @MainActor [weak self] in self?.receivePairingRequest(on: connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case let .failed(error) = state {
                    Task { @MainActor [weak self] in self?.lastError = error.localizedDescription }
                }
            }
            tcpListener = listener
            listener.start(queue: .main)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        tcpListener?.cancel()
        tcpListener = nil
        udpListener?.cancel()
        udpListener = nil
        pairedSession?.udpConnection?.cancel()
        pairedSession?.controlConnection?.cancel()
        pairedSession = nil
        Task { await networkTransport.clear() }
    }

    private func receivePairingRequest(
        on connection: NWConnection,
        decoder: PanoramaControlFrame.Decoder = .init()
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] content, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, error == nil, let content else {
                    connection.cancel()
                    return
                }
                var decoder = decoder
                guard let frames = try? decoder.append(content) else {
                    connection.cancel()
                    return
                }
                guard let frame = frames.first else {
                    self.receivePairingRequest(on: connection, decoder: decoder)
                    return
                }
                guard frames.count == 1,
                      frame.type == .pairingRequest,
                      let request = try? frame.decodeJSON(PanoramaPairingControlRequest.self),
                      request.protocolVersion == PanoramaPairingControlRequest.protocolVersion,
                      let udpPort = self.udpListener?.port?.rawValue else {
                    connection.cancel()
                    return
                }
                let peerID = UUID().uuidString.lowercased()
                let sessionKey: PanoramaSessionKey
                switch self.sessionKeyGenerator() {
                case let .success(generatedKey):
                    sessionKey = generatedKey
                case let .failure(error):
                    self.lastError = error.localizedDescription
                    Log.error(self.logger, "无法为 iPhone 配对生成会话密钥: \(error.localizedDescription)")
                    connection.cancel()
                    return
                }

                let sessionID = UUID()
                guard let pairingIdentity = self.pairingIdentity,
                      let response = try? PanoramaPairingSecurity.makeServerResponse(
                        request: request,
                        peerID: peerID,
                        sessionID: sessionID,
                        udpPort: udpPort,
                        sessionKey: sessionKey,
                        identity: pairingIdentity
                      ),
                      let responseData = try? PanoramaControlFrame.json(
                    response,
                    type: .pairingResponse
                ) else {
                    connection.cancel()
                    return
                }

                // One companion is the supported topology limit. Prepare all
                // cryptographic material first, so a local failure never
                // disconnects a companion that is already working.
                self.pairedSession?.udpConnection?.cancel()
                self.pairedSession?.controlConnection?.cancel()
                self.pairedSession = PairedSession(
                    peerID: peerID,
                    deviceName: request.deviceName,
                    outputName: request.outputName,
                    outputVolume: request.outputVolume,
                    sessionID: sessionID,
                    key: sessionKey,
                    controlConnection: connection,
                    udpConnection: nil,
                    startupPackets: 200
                )
                self.publishEndpointStatus(readiness: .available)
                connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard error == nil else {
                            connection.cancel()
                            self.disconnectControlConnection(connection, peerID: peerID)
                            return
                        }
                        self.monitorControlConnection(connection, peerID: peerID)
                    }
                })
            }
        }
    }

    private func monitorControlConnection(_ connection: NWConnection, peerID: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if error != nil || isComplete {
                    self.disconnectControlConnection(connection, peerID: peerID)
                    return
                }
                self.monitorControlConnection(connection, peerID: peerID)
            }
        }
    }

    private func disconnectControlConnection(_ connection: NWConnection, peerID: String) {
        guard var session = pairedSession,
              session.peerID == peerID,
              session.controlConnection === connection else { return }
        session.controlConnection = nil
        session.udpConnection?.cancel()
        session.udpConnection = nil
        pairedSession = session
        Task { await networkTransport.clear() }
        publishEndpointStatus(readiness: .unavailable(reason: "iPhone 控制连接已断开"))
    }

    private func startUDPListener() {
        do {
            let listener = try NWListener(using: .udp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                Task { @MainActor [weak self] in self?.receiveUDPRegistration(on: connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    switch state {
                    case .ready:
                        self?.startTCPListener()
                    case let .failed(error):
                        self?.lastError = error.localizedDescription
                    default:
                        break
                    }
                }
            }
            udpListener = listener
            listener.start(queue: .main)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func receiveUDPRegistration(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, error == nil, let content,
                      let registration = try? PanoramaUDPRegistration.decodeDatagram(content),
                      var session = self.pairedSession,
                      registration.isValid(for: session.peerID, sessionID: session.sessionID, key: session.key) else {
                    connection.cancel()
                    return
                }
                session.udpConnection?.cancel()
                session.udpConnection = connection
                session.outputName = registration.outputName
                session.outputVolume = registration.outputVolume
                self.pairedSession = session
                await self.networkTransport.configure(
                    connection: connection,
                    sessionID: session.sessionID,
                    key: session.key
                )
                self.publishEndpointStatus(readiness: .available)
                self.sendPlayoutControl(to: connection, session: session)
                self.receiveUDPStatus(on: connection)
            }
        }
    }

    private func receiveUDPStatus(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard error == nil, let content,
                      var session = self.pairedSession,
                      session.udpConnection === connection else {
                    connection.cancel()
                    if var session = self.pairedSession,
                       session.udpConnection === connection {
                        session.udpConnection = nil
                        self.pairedSession = session
                        await self.networkTransport.clear()
                    }
                    return
                }
                guard let registration = try? PanoramaUDPRegistration.decodeDatagram(content),
                      registration.isValid(for: session.peerID, sessionID: session.sessionID, key: session.key) else {
                    connection.cancel()
                    session.udpConnection = nil
                    self.pairedSession = session
                    await self.networkTransport.clear()
                    return
                }
                session.outputName = registration.outputName
                session.outputVolume = registration.outputVolume
                self.pairedSession = session
                self.publishEndpointStatus(readiness: .available)
                self.receiveUDPStatus(on: connection)
            }
        }
    }

    private func publishEndpointStatus(readiness: PanoramaEndpointAvailability) {
        guard let session = pairedSession else { return }
        onEndpointStatusChanged?(
            PanoramaCompanionEndpointStatus(
                peerID: session.peerID,
                deviceName: session.deviceName,
                outputName: session.outputName,
                outputVolume: session.outputVolume,
                availability: readiness
            )
        )
    }

    /// Publishes the companion's live output-delay target. The legacy packet
    /// field remains wire-compatible; the companion no longer rebuilds its
    /// jitter buffer when this value changes.
    func configureRemoteDelay(milliseconds: Int) {
        guard var session = pairedSession else { return }
        session.startupPackets = min(
            max(PanoramaCompanionDelayPolicy.baseStartupPackets + milliseconds / 5, 1),
            PanoramaCompanionPlayoutControl.maximumStartupPackets
        )
        pairedSession = session
        guard let connection = session.udpConnection else { return }
        sendPlayoutControl(to: connection, session: session)
    }

    private func sendPlayoutControl(to connection: NWConnection, session: PairedSession) {
        let control = PanoramaCompanionPlayoutControl.make(
            sessionID: session.sessionID,
            startupPackets: session.startupPackets,
            key: session.key
        )
        guard let payload = try? control.encodedDatagram() else { return }
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.lastError = error.localizedDescription
                self?.publishEndpointStatus(readiness: .unavailable(reason: "iPhone 网络输出已断开"))
            }
        })
    }

}

actor PanoramaNetworkTransport {
    private var connection: NWConnection?
    private var sessionID: UUID?
    private var key: PanoramaSessionKey?
    private var nextSequence: UInt64 = 0
    private var masterFrame: UInt64 = 0

    func configure(connection: NWConnection, sessionID: UUID, key: PanoramaSessionKey) {
        self.connection = connection
        self.sessionID = sessionID
        self.key = key
        nextSequence = 0
        masterFrame = 0
    }

    func clear() {
        connection = nil
        sessionID = nil
        key = nil
        nextSequence = 0
        masterFrame = 0
    }

    @discardableResult
    func send(pcm: Data) -> Bool {
        guard let connection, let sessionID, let key,
              let packet = try? PanoramaAudioPacket(
                sessionID: sessionID,
                sequence: nextSequence,
                masterFrame: masterFrame,
                pcm: pcm
              ) else { return false }
        nextSequence &+= 1
        masterFrame &+= UInt64(PanoramaAudioPacket.framesPerPacket)
        connection.send(
            content: packet.encoded(authenticatedWith: key),
            completion: .contentProcessed { _ in }
        )
        return true
    }
}

struct PanoramaCompanionEndpointStatus: Equatable, Sendable {
    let peerID: String
    let deviceName: String
    let outputName: String
    let outputVolume: Float
    let availability: PanoramaEndpointAvailability
}
