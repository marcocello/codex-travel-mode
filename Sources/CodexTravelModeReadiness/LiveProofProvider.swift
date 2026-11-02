import CryptoKit
import Darwin
import Foundation

public struct LiveProofProviderKeychainReference: Codable, Equatable, Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) throws {
        guard !service.isEmpty, !account.isEmpty else {
            throw LiveProofError.invalidValue("Keychain service and account must be non-empty")
        }
        self.service = service
        self.account = account
    }
}

public struct LiveProofProviderConfiguration: Codable, Equatable, Sendable {
    public static let schema = "codex-travel-mode-provider-config/v1"

    public let schema: String
    public let origin: String
    public let capabilityPath: String
    public let submitPath: String
    public let readbackPath: String
    public let publicKey: String
    public let keychain: LiveProofProviderKeychainReference?

    enum CodingKeys: String, CodingKey {
        case schema
        case origin
        case capabilityPath = "capability_path"
        case submitPath = "submit_path"
        case readbackPath = "readback_path"
        case publicKey = "public_key"
        case keychain
    }

    public init(
        origin: String,
        capabilityPath: String,
        submitPath: String,
        readbackPath: String,
        publicKey: String,
        keychain: LiveProofProviderKeychainReference? = nil
    ) throws {
        try Self.validateOrigin(origin)
        try Self.validatePath(capabilityPath)
        try Self.validatePath(submitPath)
        try Self.validatePath(readbackPath)
        _ = try LiveProofBase64URL.decode(publicKey, exactByteCount: 32)
        schema = Self.schema
        self.origin = origin
        self.capabilityPath = capabilityPath
        self.submitPath = submitPath
        self.readbackPath = readbackPath
        self.publicKey = publicKey
        self.keychain = keychain
    }

    public static func decodeCanonical(_ data: Data) throws -> Self {
        try LiveProofCanonicalJSON.requireObjectKeys(
            data,
            required: [
                "schema", "origin", "capability_path", "submit_path", "readback_path",
                "public_key",
            ],
            optional: ["keychain"]
        )
        let decoded = try LiveProofCanonicalJSON.decode(Self.self, from: data)
        guard decoded.schema == schema else {
            throw LiveProofError.invalidSchema("unsupported provider config schema")
        }
        let validatedKeychain = try decoded.keychain.map {
            try LiveProofProviderKeychainReference(
                service: $0.service,
                account: $0.account
            )
        }
        let validated = try Self(
            origin: decoded.origin,
            capabilityPath: decoded.capabilityPath,
            submitPath: decoded.submitPath,
            readbackPath: decoded.readbackPath,
            publicKey: decoded.publicKey,
            keychain: validatedKeychain
        )
        try requireStrictKeychainObject(data)
        guard try LiveProofCanonicalJSON.encode(validated) == data else {
            throw LiveProofError.invalidEncoding("provider config JSON is not canonical")
        }
        return validated
    }

    public var canonicalBytes: Data {
        get throws { try LiveProofCanonicalJSON.encode(self) }
    }

    private static func validateOrigin(_ value: String) throws {
        guard value.utf8.allSatisfy({ $0 < 0x80 }),
              let components = URLComponents(string: value),
              components.scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty,
              components.string == value,
              isPotentiallyPublicHost(host) else {
            throw LiveProofError.invalidValue("provider origin must be one public HTTPS origin")
        }
    }

    private static func validatePath(_ value: String) throws {
        guard value.hasPrefix("/"), !value.hasPrefix("//"),
              value.utf8.allSatisfy({ $0 < 0x80 }),
              let components = URLComponents(string: "https://proof.invalid\(value)"),
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath == value else {
            throw LiveProofError.invalidValue("provider paths must be canonical paths")
        }
    }

    private static func requireStrictKeychainObject(_ data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw LiveProofError.invalidSchema("provider config must be an object")
        }
        guard let keychain = dictionary["keychain"] else { return }
        guard let fields = keychain as? [String: Any],
              Set(fields.keys) == ["service", "account"],
              fields["service"] is String,
              fields["account"] is String else {
            throw LiveProofError.invalidSchema("invalid Keychain reference schema")
        }
    }

    private static func isPotentiallyPublicHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered == "localhost" || lowered.hasSuffix(".localhost")
            || lowered.hasSuffix(".local") { return false }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let address = UInt32(bigEndian: ipv4.s_addr)
            let first = address >> 24
            let second = (address >> 16) & 0xff
            return first != 0 && first != 10 && first != 127
                && !(first == 169 && second == 254)
                && !(first == 172 && (16...31).contains(second))
                && !(first == 192 && second == 168)
                && first < 224
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            let loopback = bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1
            return !loopback && bytes != Array(repeating: 0, count: 16)
                && bytes[0] & 0xfe != 0xfc
                && !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
        }
        return true
    }
}

public enum LiveProofSourceFamily: String, Codable, Sendable {
    case ipv4
    case ipv6
}

public struct LiveProofProviderReceipt: Codable, Equatable, Sendable {
    public static let schema = "codex-travel-mode-heartbeat-receipt/v1"
    public static let signaturePrefix = "codex-travel-mode-heartbeat/v1"

    public let schema: String
    public let runID: String
    public let scenario: ReadinessScenario
    public let sequence: Int
    public let nonce: String
    public let serverReceiveUnixMilliseconds: Int64
    public let sourceFamily: LiveProofSourceFamily
    public let sourceAddress: String
    public let signature: String

    enum CodingKeys: String, CodingKey {
        case schema
        case runID = "run_id"
        case scenario
        case sequence
        case nonce
        case serverReceiveUnixMilliseconds = "server_receive_unix_milliseconds"
        case sourceFamily = "source_family"
        case sourceAddress = "source_address"
        case signature
    }

    public init(
        runID: String,
        scenario: ReadinessScenario,
        sequence: Int,
        nonce: String,
        serverReceiveUnixMilliseconds: Int64,
        sourceFamily: LiveProofSourceFamily,
        sourceAddress: String,
        signature: String
    ) throws {
        guard LiveProofValidation.isCanonicalRunID(runID), sequence > 0,
              serverReceiveUnixMilliseconds >= 0 else {
            throw LiveProofError.invalidValue("invalid provider receipt identity or time")
        }
        _ = try LiveProofBase64URL.decode(nonce, exactByteCount: 32)
        _ = try LiveProofBase64URL.decode(
            sourceAddress,
            exactByteCount: sourceFamily == .ipv4 ? 4 : 16
        )
        _ = try LiveProofBase64URL.decode(signature, exactByteCount: 64)
        schema = Self.schema
        self.runID = runID
        self.scenario = scenario
        self.sequence = sequence
        self.nonce = nonce
        self.serverReceiveUnixMilliseconds = serverReceiveUnixMilliseconds
        self.sourceFamily = sourceFamily
        self.sourceAddress = sourceAddress
        self.signature = signature
    }

    public static func decodeStrict(_ data: Data) throws -> Self {
        try LiveProofCanonicalJSON.requireObjectKeys(
            data,
            required: [
                "schema", "run_id", "scenario", "sequence", "nonce",
                "server_receive_unix_milliseconds", "source_family", "source_address",
                "signature",
            ]
        )
        let decoded = try LiveProofCanonicalJSON.decode(Self.self, from: data)
        guard decoded.schema == schema else {
            throw LiveProofError.invalidSchema("unsupported provider receipt schema")
        }
        return try Self(
            runID: decoded.runID,
            scenario: decoded.scenario,
            sequence: decoded.sequence,
            nonce: decoded.nonce,
            serverReceiveUnixMilliseconds: decoded.serverReceiveUnixMilliseconds,
            sourceFamily: decoded.sourceFamily,
            sourceAddress: decoded.sourceAddress,
            signature: decoded.signature
        )
    }

    public var canonicalSignedBytes: Data {
        let fields = [
            Self.signaturePrefix,
            runID,
            scenario.rawValue,
            String(sequence),
            nonce,
            String(serverReceiveUnixMilliseconds),
            sourceFamily.rawValue,
            sourceAddress,
        ]
        return Data(fields.joined(separator: "\0").utf8)
    }

    public func verify(publicKeyBase64URL: String) throws {
        let rawKey = try LiveProofBase64URL.decode(
            publicKeyBase64URL,
            exactByteCount: 32
        )
        let rawSignature = try LiveProofBase64URL.decode(signature, exactByteCount: 64)
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
        } catch {
            throw LiveProofError.invalidEncoding("invalid provider Ed25519 public key")
        }
        guard key.isValidSignature(rawSignature, for: canonicalSignedBytes) else {
            throw LiveProofError.authenticationFailed
        }
    }

    public static func requireExactSequence(_ receipts: [Self]) throws {
        guard let first = receipts.first,
              receipts.allSatisfy({
                  $0.runID == first.runID && $0.scenario == first.scenario
              }) else {
            throw LiveProofError.invalidValue("provider receipts cross run or scenario")
        }
        for (index, receipt) in receipts.enumerated() where receipt.sequence != index + 1 {
            throw LiveProofError.invalidValue("provider receipt sequence has a gap or duplicate")
        }
        guard Set(receipts.map(\.nonce)).count == receipts.count else {
            throw LiveProofError.invalidValue("provider receipt nonce is duplicated")
        }
    }

    public static func requireExactSequence(
        _ receipts: [Self],
        runID: String,
        scenario: ReadinessScenario,
        expectedNonces: [String]
    ) throws {
        try requireExactSequence(receipts)
        guard receipts.count == expectedNonces.count else {
            throw LiveProofError.invalidValue("provider receipt count does not match submits")
        }
        for (receipt, nonce) in zip(receipts, expectedNonces) {
            guard receipt.runID == runID, receipt.scenario == scenario,
                  receipt.nonce == nonce else {
                throw LiveProofError.authenticationFailed
            }
        }
    }
}

public enum LiveProofArtifactSealer {
    public static let maximumArtifactBytes: Int64 = 16 * 1_024 * 1_024

    public static func seal(
        directory: URL,
        names: [String]
    ) throws -> LiveProofArtifactManifest {
        let unique = Set(names)
        guard unique.count == names.count,
              names.allSatisfy({
                  !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".."
              }) else {
            throw LiveProofError.invalidValue("artifact names must be unique basenames")
        }
        try syncDirectory(directory)
        let entries = try names.map {
            try sealFile(directory.appendingPathComponent($0), name: $0)
        }
        try syncDirectory(directory)
        return try LiveProofArtifactManifest(entries: entries)
    }

    public static func verify(
        _ manifest: LiveProofArtifactManifest,
        directory: URL
    ) throws {
        guard manifest.schema == LiveProofArtifactManifest.schema else {
            throw LiveProofError.invalidSchema("unsupported manifest schema")
        }
        let validated = try LiveProofArtifactManifest(entries: manifest.entries)
        guard validated == manifest else {
            throw LiveProofError.invalidSchema("artifact manifest is not canonical")
        }
        for entry in validated.entries {
            let observed = try inspectSealedFile(
                directory.appendingPathComponent(entry.name),
                name: entry.name
            )
            guard observed == entry else { throw LiveProofError.authenticationFailed }
        }
    }

    private static func sealFile(_ url: URL, name: String) throws
        -> LiveProofArtifactManifestEntry {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw LiveProofError.unsafeFile("could not open \(name)")
        }
        defer { _ = Darwin.close(descriptor) }
        let entry = try inspect(descriptor: descriptor, name: name, allowedModes: [0o600])
        guard Darwin.fsync(descriptor) == 0,
              Darwin.fchmod(descriptor, 0o400) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw LiveProofError.fileOperation("could not seal \(name): errno \(errno)")
        }
        return entry
    }

    private static func inspectSealedFile(_ url: URL, name: String) throws
        -> LiveProofArtifactManifestEntry {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw LiveProofError.unsafeFile("could not reopen \(name)")
        }
        defer { _ = Darwin.close(descriptor) }
        return try inspect(descriptor: descriptor, name: name, allowedModes: [0o400])
    }

    private static func inspect(
        descriptor: Int32,
        name: String,
        allowedModes: Set<mode_t>
    ) throws -> LiveProofArtifactManifestEntry {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              allowedModes.contains(info.st_mode & 0o777),
              info.st_uid == geteuid(),
              info.st_size > 0,
              info.st_size <= maximumArtifactBytes else {
            throw LiveProofError.unsafeFile("\(name) is not a bounded owned artifact")
        }
        guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw LiveProofError.fileOperation("could not seek \(name)")
        }
        let data = try readAll(descriptor: descriptor, count: Int(info.st_size), name: name)
        return try LiveProofArtifactManifestEntry(
            name: name,
            byteCount: info.st_size,
            sha256: ReadinessDigest.sha256Hex(data)
        )
    }

    private static func readAll(descriptor: Int32, count: Int, name: String) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let amount = data.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
            }
            guard amount > 0 else {
                throw LiveProofError.fileOperation("could not read complete \(name)")
            }
            offset += amount
        }
        return data
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw LiveProofError.unsafeFile("could not open artifact directory")
        }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700,
              info.st_uid == geteuid() else {
            throw LiveProofError.unsafeFile("artifact directory must be owned mode-0700")
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw LiveProofError.fileOperation("could not sync artifact directory: errno \(errno)")
        }
    }
}
