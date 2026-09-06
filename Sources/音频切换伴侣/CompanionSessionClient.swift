import Foundation
import Network
import Observation
import Security
import UIKit

struct DiscoveredCompanionHost: Identifiable, Equatable {
    let id: String
    let name: String
    let identityPublicKey: Data
    let fingerprint: String
    fileprivate let endpoint: NWEndpoint

    static func == (lhs: DiscoveredCompanionHost, rhs: DiscoveredCompanionHost) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
            && lhs.identityPublicKey == rhs.identityPublicKey
    }
}

/// Bonjour discovery and authenticated UDP reception for the iPhone endpoint.
/// The user confirms a discovered Mac before TLS exchanges a short-lived
/// session key; UDP is accepted only after HMAC, session-ID, and replay-window
/// validation succeeds.
@MainActor
@Observable
final class CompanionSessionClient {
    enum State: Equatable {
        case discovering
        case notPaired
        case connecting
        case ready
        case receiving
        case unavailable(message: String)
    }

    private(set) var hosts: [DiscoveredCompanionHost] = []
    private(set) var state: State = .notPaired
    private(set) var pairedMacName: String?
    private var currentOutputName = "iPhone 扬声器"
    private var currentOutputVolume: Float = 1
    private var browser: NWBrowser?
    private var udpConnection: NWConnection?
    private var pairingConnection: NWConnection?
    private var activeControlConnection: NWConnection?
    private var pairingTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var registrationHeartbeatTask: Task<Void, Never>?
    private var hasRegistrationAcknowledgement = false
    private let renderer = CompanionAudioRenderer()
    private let udpQueue = DispatchQueue(
        label: "com.mankeipun.yinpinqiehuan.companion.udp",
        qos: .userInitiated
    )
    private var activePeerID: String?
    private var activeSessionID: UUID?
    private var activeSessionKey: PanoramaSessionKey?
    private var lastConnectedHost: DiscoveredCompanionHost?
    private var transportGeneration: UInt64 = 0

    func startDiscovery() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_yinpin-panorama._tcp", domain: nil),
            using: .tcp
        )
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .failed(let error):
                    self?.state = .unavailable(message: CompanionLocalizedMessage.text("companion.error.discovery", error.localizedDescription))
                case .ready: self?.state = .discovering
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.compactMap { result -> DiscoveredCompanionHost? in
                guard case let .bonjour(txtRecord) = result.metadata,
                      let encodedIdentity = txtRecord["identity"],
                      let identityPublicKey = Data(base64Encoded: encodedIdentity),
                      let advertisedFingerprint = txtRecord["fingerprint"],
                      advertisedFingerprint == PanoramaPairingSecurity.fingerprint(for: identityPublicKey),
                      txtRecord["protocol"] == String(PanoramaPairingControlRequest.protocolVersion) else {
                    return nil
                }
                return DiscoveredCompanionHost(
                    id: String(describing: result.endpoint),
                    name: Self.displayName(for: result.endpoint),
                    identityPublicKey: identityPublicKey,
                    fingerprint: advertisedFingerprint,
                    endpoint: result.endpoint
                )
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor [weak self] in self?.hosts = hosts }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    /// Starts the UDP receive half after the TLS discovery channel has
    /// delivered a short-lived, Mac-issued session key and direct UDP port.
    func beginReceiving(
        from udpHost: NWEndpoint.Host,
        udpPort: UInt16,
        peerID: String,
        sessionID: UUID,
        key: PanoramaSessionKey
    ) {
        transportGeneration &+= 1
        let generation = transportGeneration
        registrationHeartbeatTask?.cancel()
        registrationHeartbeatTask = nil
        hasRegistrationAcknowledgement = false
        udpConnection?.cancel()
        guard let port = NWEndpoint.Port(rawValue: udpPort) else {
            state = .unavailable(message: CompanionLocalizedMessage.text("companion.error.invalidPort"))
            return
        }
        let endpoint = NWEndpoint.hostPort(host: udpHost, port: port)
        let connection = NWConnection(to: endpoint, using: .udp)
        udpConnection = connection
        connection.stateUpdateHandler = { [weak self] connectionState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch connectionState {
                case .ready:
                    self.registerUDPConnection(
                        connection,
                        peerID: peerID,
                        sessionID: sessionID,
                        key: key
                    )
                case let .failed(error):
                    self.failActiveTransport(
                        message: CompanionLocalizedMessage.text("companion.error.udpConnection", error.localizedDescription)
                    )
                default:
                    break
                }
            }
        }
        Task { [weak self, weak connection] in
            guard let self, let connection else { return }
            await renderer.stop()
            guard transportGeneration == generation,
                  udpConnection === connection else { return }
            do {
                try await renderer.startNewSession()
                guard transportGeneration == generation,
                      udpConnection === connection else { return }
                connection.start(queue: udpQueue)
            } catch {
                guard transportGeneration == generation,
                      udpConnection === connection else { return }
                failActiveTransport(
                    message: CompanionLocalizedMessage.text("companion.error.udpConnection", error.localizedDescription)
                )
            }
        }
    }

    func stop() {
        transportGeneration &+= 1
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        pairingConnection?.cancel()
        pairingConnection = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        activeControlConnection?.cancel()
        activeControlConnection = nil
        registrationHeartbeatTask?.cancel()
        registrationHeartbeatTask = nil
        hasRegistrationAcknowledgement = false
        browser?.cancel()
        browser = nil
        udpConnection?.cancel()
        udpConnection = nil
        Task { [renderer] in await renderer.stop() }
        activePeerID = nil
        activeSessionID = nil
        activeSessionKey = nil
        lastConnectedHost = nil
        hosts = []
        state = .notPaired
    }

    func forgetPairedMac() {
        CompanionTrustStore.removeAll()
        transportGeneration &+= 1
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        pairingConnection?.cancel()
        pairingConnection = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        lastConnectedHost = nil
        failActiveTransport(message: nil, shouldReconnect: false)
        pairedMacName = nil
        state = browser == nil ? .notPaired : .discovering
    }

    func connectToFirstDiscoveredHost() {
        guard let host = hosts.first else {
            state = .unavailable(message: CompanionLocalizedMessage.text("companion.error.noHost"))
            return
        }
        connect(to: host)
    }

    func connect(to host: DiscoveredCompanionHost) {
        reconnectTask?.cancel()
        reconnectTask = nil
        lastConnectedHost = host
        pairingTimeoutTask?.cancel()
        pairingConnection?.cancel()
        state = .connecting
        let connection = NWConnection(to: host.endpoint, using: PanoramaPairingTLS.automaticParameters())
        pairingConnection = connection
        pairingTimeoutTask = Task { [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled,
                  let self,
                  let connection,
                  self.pairingConnection === connection,
                  self.state == .connecting else { return }
            self.clearPairingAttempt(for: connection)
            connection.cancel()
            self.state = .unavailable(message: CompanionLocalizedMessage.text("companion.error.timeout"))
        }
        connection.stateUpdateHandler = { [weak self] connectionState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch connectionState {
                case .ready:
                    guard self.pairingConnection === connection else { return }
                    guard case let .hostPort(udpHost, _) = connection.currentPath?.remoteEndpoint else {
                        self.failPairing(on: connection, message: CompanionLocalizedMessage.text("companion.error.macAddress"))
                        return
                    }
                    let handshake = PanoramaClientHandshake()
                    let request = PanoramaPairingControlRequest(
                        protocolVersion: PanoramaPairingControlRequest.protocolVersion,
                        deviceName: UIDevice.current.name,
                        outputName: self.currentOutputName,
                        outputVolume: self.currentOutputVolume,
                        clientEphemeralPublicKey: handshake.privateKey.publicKey.rawRepresentation,
                        clientNonce: handshake.nonce
                    )
                    guard let data = try? PanoramaControlFrame.json(request, type: .pairingRequest) else {
                        self.failPairing(on: connection, message: CompanionLocalizedMessage.text("companion.error.pairingRequest"))
                        return
                    }
                    connection.send(content: data, completion: .contentProcessed { error in
                        guard let error else { return }
                        Task { @MainActor [weak self] in
                            self?.failPairing(on: connection, message: CompanionLocalizedMessage.text("companion.error.sendPairing", error.localizedDescription))
                        }
                    })
                    self.receivePairingResponse(
                        on: connection,
                        host: host,
                        udpHost: udpHost,
                        request: request,
                        handshake: handshake
                    )
                case let .waiting(error):
                    if self.activeControlConnection === connection {
                        self.failActiveTransport(message: CompanionLocalizedMessage.text("companion.error.controlConnection", error.localizedDescription))
                    } else {
                        self.failPairing(on: connection, message: CompanionLocalizedMessage.text("companion.error.connect", error.localizedDescription))
                    }
                case let .failed(error):
                    if self.activeControlConnection === connection {
                        self.failActiveTransport(message: CompanionLocalizedMessage.text("companion.error.controlConnection", error.localizedDescription))
                    } else {
                        self.failPairing(on: connection, message: CompanionLocalizedMessage.text("companion.error.connection", error.localizedDescription))
                    }
                case .cancelled:
                    if self.activeControlConnection === connection {
                        self.failActiveTransport(message: CompanionLocalizedMessage.text("companion.error.controlDisconnected"))
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    func updateCurrentOutput(name outputName: String, volume: Float) {
        currentOutputName = outputName
        currentOutputVolume = min(max(volume, 0), 1)
        sendCurrentOutputStatus()
    }

    /// Route changes, interruptions, and Bluetooth handoffs can stop an
    /// AVAudioEngine without ending the authenticated network session.
    func reactivateAudioRenderer() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await renderer.restartAfterRouteChange()
            } catch {
                state = .unavailable(message: CompanionLocalizedMessage.text("companion.error.restoreOutput", error.localizedDescription))
            }
        }
    }

    private func sendCurrentOutputStatus() {
        guard let connection = udpConnection,
              let data = currentRegistrationData() else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Register only after the direct UDP connection is ready. Registration is
    /// retried until the Mac acknowledges it with authenticated playout control.
    private func registerUDPConnection(
        _ connection: NWConnection,
        peerID: String,
        sessionID: UUID,
        key: PanoramaSessionKey
    ) {
        guard udpConnection === connection else { return }
        Self.receiveNextPacket(
            connection,
            sessionID: sessionID,
            key: key,
            renderer: renderer
        ) { [weak self, weak connection] event in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection, self.udpConnection === connection else { return }
                switch event {
                case let .playoutConfigured(startupPackets):
                    hasRegistrationAcknowledgement = true
                    state = .ready
                    _ = startupPackets
                case .firstAudioPacket:
                    state = .receiving
                case .ignored:
                    break
                }
            }
        }
        activePeerID = peerID
        activeSessionID = sessionID
        activeSessionKey = key
        guard currentRegistrationData() != nil else {
            state = .unavailable(message: CompanionLocalizedMessage.text("companion.error.networkRegistration"))
            connection.cancel()
            return
        }
        state = .ready
        registrationHeartbeatTask?.cancel()
        registrationHeartbeatTask = Task { [weak self, weak connection] in
            var attemptsWithoutAcknowledgement = 0
            while !Task.isCancelled {
                guard !Task.isCancelled,
                      let self,
                      let connection,
                      self.udpConnection === connection else { return }
                guard let registrationData = self.currentRegistrationData() else { return }
                connection.send(content: registrationData, completion: .contentProcessed { error in
                    guard let error else { return }
                    Task { @MainActor [weak self] in
                        self?.failActiveTransport(
                            message: CompanionLocalizedMessage.text("companion.error.networkRegistrationFailed", error.localizedDescription)
                        )
                    }
                })
                if self.hasRegistrationAcknowledgement {
                    attemptsWithoutAcknowledgement = 0
                    try? await Task.sleep(for: .seconds(2))
                } else {
                    attemptsWithoutAcknowledgement += 1
                    if attemptsWithoutAcknowledgement >= 20 {
                        self.state = .unavailable(message: CompanionLocalizedMessage.text("companion.error.networkUnconfirmed"))
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    private func currentRegistrationData() -> Data? {
        guard let peerID = activePeerID,
              let sessionID = activeSessionID,
              let key = activeSessionKey else { return nil }
        return try? PanoramaUDPRegistration.make(
                peerID: peerID,
                sessionID: sessionID,
                outputName: currentOutputName,
                outputVolume: currentOutputVolume,
                key: key
            ).encodedDatagram()
    }

    /// Receive one datagram at a time so authenticated decoding and renderer
    /// insertion provide back-pressure instead of creating an unbounded task
    /// burst on a busy Wi-Fi connection.
    private nonisolated static func receiveNextPacket(
        _ connection: NWConnection,
        sessionID: UUID,
        key: PanoramaSessionKey,
        renderer: CompanionAudioRenderer,
        onEvent: @escaping @Sendable (CompanionInboundAudioEvent) -> Void
    ) {
        connection.receiveMessage { content, _, _, error in
            guard error == nil else { return }
            Task {
                if let content {
                    let event = await renderer.consume(content, sessionID: sessionID, key: key)
                    if case .ignored = event {
                        // Avoid crossing to the main actor for routine audio packets.
                    } else {
                        onEvent(event)
                    }
                }
                receiveNextPacket(
                    connection,
                    sessionID: sessionID,
                    key: key,
                    renderer: renderer,
                    onEvent: onEvent
                )
            }
        }
    }

    private func receivePairingResponse(
        on connection: NWConnection,
        host: DiscoveredCompanionHost,
        udpHost: NWEndpoint.Host,
        request: PanoramaPairingControlRequest,
        handshake: PanoramaClientHandshake,
        decoder: PanoramaControlFrame.Decoder = .init()
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] content, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, error == nil, let content else {
                    self?.failPairing(on: connection, message: CompanionLocalizedMessage.text("companion.error.macRejected"))
                    return
                }
                var decoder = decoder
                guard let frames = try? decoder.append(content) else {
                    self.failPairing(on: connection, message: CompanionLocalizedMessage.text("companion.error.macRejected"))
                    return
                }
                guard let frame = frames.first else {
                    self.receivePairingResponse(
                        on: connection,
                        host: host,
                        udpHost: udpHost,
                        request: request,
                        handshake: handshake,
                        decoder: decoder
                    )
                    return
                }
                guard frames.count == 1,
                      frame.type == .pairingResponse,
                      let response = try? frame.decodeJSON(PanoramaPairingControlResponse.self),
                      response.protocolVersion == PanoramaPairingControlRequest.protocolVersion,
                      CompanionTrustStore.accepts(
                        identityPublicKey: host.identityPublicKey,
                        macName: host.name
                      ),
                      let sessionKey = try? PanoramaPairingSecurity.openServerResponse(
                        response,
                        request: request,
                        handshake: handshake,
                        expectedIdentityPublicKey: host.identityPublicKey
                      ) else {
                    self.failPairing(on: connection, message: CompanionLocalizedMessage.text("companion.error.macRejected"))
                    return
                }
                self.clearPairingAttempt(for: connection)
                _ = CompanionTrustStore.save(
                    identityPublicKey: host.identityPublicKey,
                    macName: host.name
                )
                self.activeControlConnection?.cancel()
                self.activeControlConnection = connection
                self.pairedMacName = host.name
                self.beginReceiving(
                    from: udpHost,
                    udpPort: response.udpPort,
                    peerID: response.peerID,
                    sessionID: response.sessionID,
                    key: sessionKey
                )
            }
        }
    }

    private func failPairing(on connection: NWConnection, message: String) {
        guard pairingConnection === connection else { return }
        clearPairingAttempt(for: connection)
        connection.cancel()
        state = .unavailable(message: message)
    }

    private func clearPairingAttempt(for connection: NWConnection) {
        guard pairingConnection === connection else { return }
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        pairingConnection = nil
    }

    private func failActiveTransport(message: String?, shouldReconnect: Bool = true) {
        transportGeneration &+= 1
        registrationHeartbeatTask?.cancel()
        registrationHeartbeatTask = nil
        hasRegistrationAcknowledgement = false
        udpConnection?.cancel()
        udpConnection = nil
        activeControlConnection?.cancel()
        activeControlConnection = nil
        activePeerID = nil
        activeSessionID = nil
        activeSessionKey = nil
        Task { [renderer] in await renderer.stop() }
        if let message {
            state = .unavailable(message: message)
        }
        guard shouldReconnect, let host = lastConnectedHost, browser != nil else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.browser != nil else { return }
            self.connect(to: host)
        }
    }

    private nonisolated static func displayName(for endpoint: NWEndpoint) -> String {
        if case let .service(name, _, _, _) = endpoint { return name }
        return String(describing: endpoint)
    }
}

private enum CompanionTrustStore {
    private static let service = "com.mankeipun.yinpinqiehuan.companion.trusted-mac"

    static func accepts(identityPublicKey: Data, macName: String) -> Bool {
        guard let stored = load(macName: macName) else { return true }
        return stored == identityPublicKey
    }

    static func save(identityPublicKey: Data, macName: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: macName,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData] = identityPublicKey
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func removeAll() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ] as CFDictionary)
    }

    private static func load(macName: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: macName,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
}
