import Foundation

public enum LiveProofError: Error, Equatable, Sendable {
    case invalidEncoding(String)
    case invalidSchema(String)
    case invalidValue(String)
    case authenticationFailed
    case expiredReceipt
    case receiptAlreadyConsumed
    case unsafeFile(String)
    case fileOperation(String)
}

public enum LiveProofBase64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ value: String, exactByteCount: Int? = nil) throws -> Data {
        guard !value.isEmpty, !value.contains("="),
              value.utf8.allSatisfy({ Self.allowed.contains($0) }) else {
            throw LiveProofError.invalidEncoding("base64url must be unpadded ASCII")
        }
        let remainder = value.utf8.count % 4
        guard remainder != 1 else {
            throw LiveProofError.invalidEncoding("invalid base64url length")
        }
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - remainder) % 4)
        guard let decoded = Data(base64Encoded: standard),
              encode(decoded) == value,
              exactByteCount.map({ decoded.count == $0 }) ?? true else {
            throw LiveProofError.invalidEncoding("non-canonical base64url")
        }
        return decoded
    }

    private static let allowed = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8
    )
}

public enum LiveProofCanonicalJSON {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func requireObjectKeys(
        _ data: Data,
        required: Set<String>,
        optional: Set<String> = []
    ) throws {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw LiveProofError.invalidSchema("top-level JSON value must be an object")
        }
        let keys = Set(dictionary.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
            throw LiveProofError.invalidSchema("JSON object has missing or unknown fields")
        }
    }

    public static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LiveProofError.invalidSchema("JSON does not match the declared schema")
        }
    }
}

public struct LiveProofProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let startIdentity: String
    public let executableSHA256: String

    enum CodingKeys: String, CodingKey {
        case pid
        case startIdentity = "start_identity"
        case executableSHA256 = "executable_sha256"
    }

    public init(pid: Int32, startIdentity: String, executableSHA256: String) throws {
        guard pid > 0, !startIdentity.isEmpty,
              LiveProofValidation.isSHA256Hex(executableSHA256) else {
            throw LiveProofError.invalidValue("invalid process identity")
        }
        self.pid = pid
        self.startIdentity = startIdentity
        self.executableSHA256 = executableSHA256
    }
}

public struct LiveProofArmingBinding: Codable, Equatable, Sendable {
    public let runID: String
    public let machineDigest: String
    public let baselineDigest: String
    public let controllerSHA256: String
    public let observer: LiveProofProcessIdentity
    public let observerPublicKey: String
    public let appIdentityDigest: String
    public let helperIdentityDigest: String
    public let providerOrigin: String
    public let outputDirectoryDigest: String
    public let targetSSIDDigest: String?
    public let wifiDeviceDigest: String?

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case machineDigest = "machine_digest"
        case baselineDigest = "baseline_digest"
        case controllerSHA256 = "controller_sha256"
        case observer
        case observerPublicKey = "observer_public_key"
        case appIdentityDigest = "app_identity_digest"
        case helperIdentityDigest = "helper_identity_digest"
        case providerOrigin = "provider_origin"
        case outputDirectoryDigest = "output_directory_digest"
        case targetSSIDDigest = "target_ssid_digest"
        case wifiDeviceDigest = "wifi_device_digest"
    }

    public init(
        runID: String,
        machineDigest: String,
        baselineDigest: String,
        controllerSHA256: String,
        observer: LiveProofProcessIdentity,
        observerPublicKey: String,
        appIdentityDigest: String,
        helperIdentityDigest: String,
        providerOrigin: String,
        outputDirectoryDigest: String,
        targetSSIDDigest: String? = nil,
        wifiDeviceDigest: String? = nil
    ) throws {
        guard LiveProofValidation.isCanonicalRunID(runID),
              LiveProofValidation.isSHA256Hex(machineDigest),
              LiveProofValidation.isSHA256Hex(baselineDigest),
              LiveProofValidation.isSHA256Hex(controllerSHA256),
              LiveProofValidation.isSHA256Hex(appIdentityDigest),
              LiveProofValidation.isSHA256Hex(helperIdentityDigest),
              LiveProofValidation.isSHA256Hex(outputDirectoryDigest),
              targetSSIDDigest.map(LiveProofValidation.isSHA256Hex) ?? true,
              wifiDeviceDigest.map(LiveProofValidation.isSHA256Hex) ?? true,
              (targetSSIDDigest == nil) == (wifiDeviceDigest == nil) else {
            throw LiveProofError.invalidValue("arming binding contains a non-canonical identifier")
        }
        _ = try LiveProofBase64URL.decode(observerPublicKey, exactByteCount: 32)
        guard providerOrigin.hasPrefix("https://") else {
            throw LiveProofError.invalidValue("provider origin must use HTTPS")
        }
        self.runID = runID
        self.machineDigest = machineDigest
        self.baselineDigest = baselineDigest
        self.controllerSHA256 = controllerSHA256
        self.observer = observer
        self.observerPublicKey = observerPublicKey
        self.appIdentityDigest = appIdentityDigest
        self.helperIdentityDigest = helperIdentityDigest
        self.providerOrigin = providerOrigin
        self.outputDirectoryDigest = outputDirectoryDigest
        self.targetSSIDDigest = targetSSIDDigest
        self.wifiDeviceDigest = wifiDeviceDigest
    }
}

public struct LiveProofArmingReceipt: Codable, Equatable, Sendable {
    public static let schema = "codex-travel-mode-arming-receipt/v1"

    public let schema: String
    public let issuedAtUnixMilliseconds: Int64
    public let expiresAtUnixMilliseconds: Int64
    public let challengeSHA256: String
    public let binding: LiveProofArmingBinding
    public let authenticationCode: String

    enum CodingKeys: String, CodingKey {
        case schema
        case issuedAtUnixMilliseconds = "issued_at_unix_milliseconds"
        case expiresAtUnixMilliseconds = "expires_at_unix_milliseconds"
        case challengeSHA256 = "challenge_sha256"
        case binding
        case authenticationCode = "authentication_code"
    }

    public init(
        issuedAtUnixMilliseconds: Int64,
        expiresAtUnixMilliseconds: Int64,
        challengeSHA256: String,
        binding: LiveProofArmingBinding,
        authenticationCode: String
    ) {
        schema = Self.schema
        self.issuedAtUnixMilliseconds = issuedAtUnixMilliseconds
        self.expiresAtUnixMilliseconds = expiresAtUnixMilliseconds
        self.challengeSHA256 = challengeSHA256
        self.binding = binding
        self.authenticationCode = authenticationCode
    }
}

public enum LiveProofHandshakePhase: String, Codable, Sendable {
    case preflight
    case live
}

public struct LiveProofHandshakePayload: Codable, Equatable, Sendable {
    public static let schema = "codex-travel-mode-observer-handshake-payload/v1"

    public let schema: String
    public let runID: String
    public let phase: LiveProofHandshakePhase
    public let client: LiveProofProcessIdentity
    public let controllerSHA256: String
    public let requestSequenceStart: Int

    enum CodingKeys: String, CodingKey {
        case schema
        case runID = "run_id"
        case phase
        case client
        case controllerSHA256 = "controller_sha256"
        case requestSequenceStart = "request_sequence_start"
    }

    public init(
        runID: String,
        phase: LiveProofHandshakePhase,
        client: LiveProofProcessIdentity,
        controllerSHA256: String,
        requestSequenceStart: Int
    ) throws {
        guard LiveProofValidation.isCanonicalRunID(runID),
              LiveProofValidation.isSHA256Hex(controllerSHA256),
              requestSequenceStart > 0 else {
            throw LiveProofError.invalidValue("invalid handshake payload")
        }
        schema = Self.schema
        self.runID = runID
        self.phase = phase
        self.client = client
        self.controllerSHA256 = controllerSHA256
        self.requestSequenceStart = requestSequenceStart
    }
}

public struct LiveProofSignedPayload: Codable, Equatable, Sendable {
    public let payloadBase64URL: String
    public let signatureBase64URL: String

    enum CodingKeys: String, CodingKey {
        case payloadBase64URL = "payload_base64url"
        case signatureBase64URL = "signature_base64url"
    }

    public init(payloadBase64URL: String, signatureBase64URL: String) {
        self.payloadBase64URL = payloadBase64URL
        self.signatureBase64URL = signatureBase64URL
    }
}

public struct LiveProofSignedEventEnvelope: Codable, Equatable, Sendable {
    public static let genesisPreviousSHA256 = String(repeating: "0", count: 64)

    public let payloadBase64URL: String
    public let previousEnvelopeSHA256: String
    public let signatureBase64URL: String

    enum CodingKeys: String, CodingKey {
        case payloadBase64URL = "payload_base64url"
        case previousEnvelopeSHA256 = "previous_envelope_sha256"
        case signatureBase64URL = "signature_base64url"
    }

    public init(
        payloadBase64URL: String,
        previousEnvelopeSHA256: String,
        signatureBase64URL: String
    ) {
        self.payloadBase64URL = payloadBase64URL
        self.previousEnvelopeSHA256 = previousEnvelopeSHA256
        self.signatureBase64URL = signatureBase64URL
    }
}

public struct LiveProofArtifactManifestEntry: Codable, Equatable, Sendable {
    public let name: String
    public let byteCount: Int64
    public let sha256: String

    enum CodingKeys: String, CodingKey {
        case name
        case byteCount = "byte_count"
        case sha256
    }

    public init(name: String, byteCount: Int64, sha256: String) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..",
              byteCount > 0, LiveProofValidation.isSHA256Hex(sha256) else {
            throw LiveProofError.invalidValue("invalid artifact manifest entry")
        }
        self.name = name
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct LiveProofArtifactManifest: Codable, Equatable, Sendable {
    public static let schema = "codex-travel-mode-seal-manifest/v1"

    public let schema: String
    public let entries: [LiveProofArtifactManifestEntry]

    public init(entries: [LiveProofArtifactManifestEntry]) throws {
        let sorted = entries.sorted { $0.name < $1.name }
        guard !sorted.isEmpty, Set(sorted.map(\.name)).count == sorted.count,
              sorted.allSatisfy({
                  !$0.name.isEmpty && !$0.name.contains("/") && $0.byteCount > 0
                      && LiveProofValidation.isSHA256Hex($0.sha256)
              }) else {
            throw LiveProofError.invalidValue("invalid artifact manifest entry")
        }
        schema = Self.schema
        self.entries = sorted
    }
}

public struct LiveProofObserverSealPayload: Codable, Equatable, Sendable {
    public static let schema = "codex-travel-mode-observer-seal-payload/v1"

    public let schema: String
    public let runID: String
    public let observer: LiveProofProcessIdentity
    public let observerPublicKey: String
    public let eventCount: Int
    public let finalEnvelopeSHA256: String
    public let observerOwnedFiles: [LiveProofArtifactManifestEntry]

    enum CodingKeys: String, CodingKey {
        case schema
        case runID = "run_id"
        case observer
        case observerPublicKey = "observer_public_key"
        case eventCount = "event_count"
        case finalEnvelopeSHA256 = "final_envelope_sha256"
        case observerOwnedFiles = "observer_owned_files"
    }

    public init(
        runID: String,
        observer: LiveProofProcessIdentity,
        observerPublicKey: String,
        eventCount: Int,
        finalEnvelopeSHA256: String,
        observerOwnedFiles: [LiveProofArtifactManifestEntry]
    ) throws {
        guard LiveProofValidation.isCanonicalRunID(runID), eventCount >= 0,
              LiveProofValidation.isSHA256Hex(finalEnvelopeSHA256) else {
            throw LiveProofError.invalidValue("invalid observer seal payload")
        }
        _ = try LiveProofBase64URL.decode(observerPublicKey, exactByteCount: 32)
        let manifest = try LiveProofArtifactManifest(entries: observerOwnedFiles)
        schema = Self.schema
        self.runID = runID
        self.observer = observer
        self.observerPublicKey = observerPublicKey
        self.eventCount = eventCount
        self.finalEnvelopeSHA256 = finalEnvelopeSHA256
        self.observerOwnedFiles = manifest.entries
    }
}

public enum LiveProofValidation {
    public static func isCanonicalRunID(_ value: String) -> Bool {
        guard value.utf8.count == 36, value == value.lowercased(),
              let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    public static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    }
}
