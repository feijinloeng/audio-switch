import CryptoKit
import Foundation
import Network
import Security

enum PanoramaPairingSecurityError: Error, Equatable {
    case invalidKeyMaterial
    case invalidNonce
    case identityMismatch
    case invalidSignature
    case keyAgreementFailed
    case keychain(OSStatus)
}

/// The old transport used one PSK embedded in every installation. Pairing now
/// uses a per-Mac signing identity plus ephemeral X25519 key agreement. TCP is
/// only a byte transport; the issued audio session key is sealed end-to-end
/// and bound to the user-verifiable Mac identity fingerprint.
enum PanoramaPairingTLS {
    static func automaticParameters() -> NWParameters { .tcp }
}

struct PanoramaPairingIdentity: Sendable {
    let privateKey: Curve25519.Signing.PrivateKey

    var publicKeyData: Data { privateKey.publicKey.rawRepresentation }
    var fingerprint: String { PanoramaPairingSecurity.fingerprint(for: publicKeyData) }
}

enum PanoramaPairingIdentityStore {
    private static let service = "com.mankeipun.yinpinqiehuan.panorama.identity"
    private static let account = "mac-signing-v1"

    static func loadOrCreate() throws -> PanoramaPairingIdentity {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return PanoramaPairingIdentity(privateKey: key)
        }
        guard status == errSecItemNotFound else {
            throw PanoramaPairingSecurityError.keychain(status)
        }

        let key = Curve25519.Signing.PrivateKey()
        var add = query
        add.removeValue(forKey: kSecReturnData)
        add.removeValue(forKey: kSecMatchLimit)
        add[kSecValueData] = key.rawRepresentation
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PanoramaPairingSecurityError.keychain(addStatus)
        }
        return PanoramaPairingIdentity(privateKey: key)
    }
}

struct PanoramaClientHandshake: Sendable {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let nonce: Data

    init() {
        privateKey = Curve25519.KeyAgreement.PrivateKey()
        nonce = PanoramaPairingSecurity.randomNonce()
    }
}

enum PanoramaPairingSecurity {
    static let nonceByteCount = 32

    static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Secure random source unavailable")
        return Data(bytes)
    }

    static func fingerprint(for publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02X", $0) }
            .chunked(every: 4)
            .joined(separator: "-")
    }

    static func makeServerResponse(
        request: PanoramaPairingControlRequest,
        peerID: String,
        sessionID: UUID,
        udpPort: UInt16,
        sessionKey: PanoramaSessionKey,
        identity: PanoramaPairingIdentity
    ) throws -> PanoramaPairingControlResponse {
        guard request.clientNonce.count == nonceByteCount else {
            throw PanoramaPairingSecurityError.invalidNonce
        }
        let clientPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            clientPublicKey = try .init(rawRepresentation: request.clientEphemeralPublicKey)
        } catch {
            throw PanoramaPairingSecurityError.invalidKeyMaterial
        }
        let serverPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let serverNonce = randomNonce()
        let base = try transcript(
            request: request,
            peerID: peerID,
            sessionID: sessionID,
            udpPort: udpPort,
            identityPublicKey: identity.publicKeyData,
            serverEphemeralPublicKey: serverPrivateKey.publicKey.rawRepresentation,
            serverNonce: serverNonce
        )
        let secret = try serverPrivateKey.sharedSecretFromKeyAgreement(with: clientPublicKey)
        let key = derivedKey(secret: secret, request: request, serverNonce: serverNonce, transcript: base)
        let sealed = try ChaChaPoly.seal(sessionKey.data, using: key, authenticating: base)
        let combined = sealed.combined
        let signature = try identity.privateKey.signature(for: base + combined)
        return PanoramaPairingControlResponse(
            protocolVersion: PanoramaPairingControlRequest.protocolVersion,
            peerID: peerID,
            sessionID: sessionID,
            udpPort: udpPort,
            identityPublicKey: identity.publicKeyData,
            serverEphemeralPublicKey: serverPrivateKey.publicKey.rawRepresentation,
            serverNonce: serverNonce,
            sealedSessionKey: combined,
            signature: signature
        )
    }

    static func openServerResponse(
        _ response: PanoramaPairingControlResponse,
        request: PanoramaPairingControlRequest,
        handshake: PanoramaClientHandshake,
        expectedIdentityPublicKey: Data
    ) throws -> PanoramaSessionKey {
        guard response.identityPublicKey == expectedIdentityPublicKey else {
            throw PanoramaPairingSecurityError.identityMismatch
        }
        guard response.serverNonce.count == nonceByteCount else {
            throw PanoramaPairingSecurityError.invalidNonce
        }
        let signingKey: Curve25519.Signing.PublicKey
        let serverPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            signingKey = try .init(rawRepresentation: response.identityPublicKey)
            serverPublicKey = try .init(rawRepresentation: response.serverEphemeralPublicKey)
        } catch {
            throw PanoramaPairingSecurityError.invalidKeyMaterial
        }
        let base = try transcript(
            request: request,
            peerID: response.peerID,
            sessionID: response.sessionID,
            udpPort: response.udpPort,
            identityPublicKey: response.identityPublicKey,
            serverEphemeralPublicKey: response.serverEphemeralPublicKey,
            serverNonce: response.serverNonce
        )
        guard signingKey.isValidSignature(response.signature, for: base + response.sealedSessionKey) else {
            throw PanoramaPairingSecurityError.invalidSignature
        }
        let secret = try handshake.privateKey.sharedSecretFromKeyAgreement(with: serverPublicKey)
        let key = derivedKey(secret: secret, request: request, serverNonce: response.serverNonce, transcript: base)
        let sealed = try ChaChaPoly.SealedBox(combined: response.sealedSessionKey)
        let sessionKeyData = try ChaChaPoly.open(sealed, using: key, authenticating: base)
        guard let sessionKey = PanoramaSessionKey(data: sessionKeyData) else {
            throw PanoramaPairingSecurityError.invalidKeyMaterial
        }
        return sessionKey
    }

    private struct Transcript: Codable {
        let protocolVersion: Int
        let deviceName: String
        let outputName: String
        let outputVolume: Float
        let clientEphemeralPublicKey: Data
        let clientNonce: Data
        let peerID: String
        let sessionID: UUID
        let udpPort: UInt16
        let identityPublicKey: Data
        let serverEphemeralPublicKey: Data
        let serverNonce: Data
    }

    private static func transcript(
        request: PanoramaPairingControlRequest,
        peerID: String,
        sessionID: UUID,
        udpPort: UInt16,
        identityPublicKey: Data,
        serverEphemeralPublicKey: Data,
        serverNonce: Data
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(
            Transcript(
                protocolVersion: request.protocolVersion,
                deviceName: request.deviceName,
                outputName: request.outputName,
                outputVolume: request.outputVolume,
                clientEphemeralPublicKey: request.clientEphemeralPublicKey,
                clientNonce: request.clientNonce,
                peerID: peerID,
                sessionID: sessionID,
                udpPort: udpPort,
                identityPublicKey: identityPublicKey,
                serverEphemeralPublicKey: serverEphemeralPublicKey,
                serverNonce: serverNonce
            )
        )
    }

    private static func derivedKey(
        secret: SharedSecret,
        request: PanoramaPairingControlRequest,
        serverNonce: Data,
        transcript: Data
    ) -> SymmetricKey {
        let salt = Data(SHA256.hash(data: request.clientNonce + serverNonce))
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: transcript,
            outputByteCount: 32
        )
    }
}

private extension Array where Element == String {
    func chunked(every size: Int) -> [String] {
        stride(from: 0, to: count, by: size).map { index in
            self[index ..< Swift.min(index + size, count)].joined()
        }
    }
}
