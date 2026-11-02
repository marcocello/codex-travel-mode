import CryptoKit
import Foundation

public enum LiveProofSignatureDomain: String, Sendable {
    case handshake = "codex-travel-mode-observer-handshake/v1"
    case event = "codex-travel-mode-observer-event/v1"
    case seal = "codex-travel-mode-observer-seal/v1"

    public func message(payload: Data) -> Data {
        var message = Data(rawValue.utf8)
        message.append(0)
        message.append(payload)
        return message
    }
}

public final class LiveProofEphemeralSigner: @unchecked Sendable {
    private let privateKey: Curve25519.Signing.PrivateKey

    public init() {
        privateKey = Curve25519.Signing.PrivateKey()
    }

    init(rawPrivateKey: Data) throws {
        privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
    }

    public var publicKeyBase64URL: String {
        LiveProofBase64URL.encode(privateKey.publicKey.rawRepresentation)
    }

    public func signature(payload: Data, domain: LiveProofSignatureDomain) throws -> Data {
        try privateKey.signature(for: domain.message(payload: payload))
    }

    public func signedPayload(
        _ payload: Data,
        domain: LiveProofSignatureDomain
    ) throws -> LiveProofSignedPayload {
        LiveProofSignedPayload(
            payloadBase64URL: LiveProofBase64URL.encode(payload),
            signatureBase64URL: LiveProofBase64URL.encode(
                try signature(payload: payload, domain: domain)
            )
        )
    }

    public func signedHandshake(
        _ handshake: LiveProofHandshakePayload
    ) throws -> LiveProofSignedPayload {
        try signedPayload(
            LiveProofCanonicalJSON.encode(handshake),
            domain: .handshake
        )
    }

    public func eventEnvelope(
        payload: Data,
        previous: LiveProofSignedEventEnvelope?
    ) throws -> LiveProofSignedEventEnvelope {
        guard !payload.isEmpty, String(data: payload, encoding: .utf8) != nil else {
            throw LiveProofError.invalidEncoding("observer event payload must be UTF-8")
        }
        let previousHash = try previous.map(Self.envelopeSHA256)
            ?? LiveProofSignedEventEnvelope.genesisPreviousSHA256
        return LiveProofSignedEventEnvelope(
            payloadBase64URL: LiveProofBase64URL.encode(payload),
            previousEnvelopeSHA256: previousHash,
            signatureBase64URL: LiveProofBase64URL.encode(
                try signature(payload: payload, domain: .event)
            )
        )
    }

    public func signedSeal(
        _ seal: LiveProofObserverSealPayload
    ) throws -> LiveProofSignedPayload {
        try signedPayload(LiveProofCanonicalJSON.encode(seal), domain: .seal)
    }

    public static func envelopeSHA256(
        _ envelope: LiveProofSignedEventEnvelope
    ) throws -> String {
        ReadinessDigest.sha256Hex(try LiveProofCanonicalJSON.encode(envelope))
    }
}

public enum LiveProofSignatureVerifier {
    public static func verify(
        _ signed: LiveProofSignedPayload,
        domain: LiveProofSignatureDomain,
        publicKeyBase64URL: String
    ) throws -> Data {
        let payload = try LiveProofBase64URL.decode(signed.payloadBase64URL)
        let signature = try LiveProofBase64URL.decode(
            signed.signatureBase64URL,
            exactByteCount: 64
        )
        try verify(
            signature: signature,
            payload: payload,
            domain: domain,
            publicKeyBase64URL: publicKeyBase64URL
        )
        return payload
    }

    public static func verify(
        signature: Data,
        payload: Data,
        domain: LiveProofSignatureDomain,
        publicKeyBase64URL: String
    ) throws {
        let rawKey = try LiveProofBase64URL.decode(
            publicKeyBase64URL,
            exactByteCount: 32
        )
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
        } catch {
            throw LiveProofError.invalidEncoding("invalid Ed25519 public key")
        }
        guard key.isValidSignature(signature, for: domain.message(payload: payload)) else {
            throw LiveProofError.authenticationFailed
        }
    }

    public static func verifyEventEnvelope(
        _ envelope: LiveProofSignedEventEnvelope,
        previous: LiveProofSignedEventEnvelope?,
        publicKeyBase64URL: String
    ) throws -> Data {
        let expectedPrevious = try previous.map(LiveProofEphemeralSigner.envelopeSHA256)
            ?? LiveProofSignedEventEnvelope.genesisPreviousSHA256
        guard envelope.previousEnvelopeSHA256 == expectedPrevious else {
            throw LiveProofError.authenticationFailed
        }
        let signed = LiveProofSignedPayload(
            payloadBase64URL: envelope.payloadBase64URL,
            signatureBase64URL: envelope.signatureBase64URL
        )
        return try verify(signed, domain: .event, publicKeyBase64URL: publicKeyBase64URL)
    }
}
