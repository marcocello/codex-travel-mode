import Foundation

public struct HotspotConfigurationRevision: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let revisionID: String
    public let ssid: String
    public let wifiDevice: String?
    public let credentialReference: String

    public init(
        revisionID: String = UUID().uuidString,
        ssid: String,
        wifiDevice: String?,
        credentialReference: String
    ) throws {
        try Self.validateSSID(ssid)
        try Self.validateWiFiDevice(wifiDevice)
        guard !revisionID.isEmpty else {
            throw HotspotConfigurationError.invalidRevisionID
        }
        guard !credentialReference.isEmpty else {
            throw HotspotConfigurationError.invalidCredentialReference
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.revisionID = revisionID
        self.ssid = ssid
        self.wifiDevice = wifiDevice
        self.credentialReference = credentialReference
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case revisionID = "revision_id"
        case ssid
        case wifiDevice = "wifi_device"
        case credentialReference = "credential_reference"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw HotspotConfigurationError.unsupportedSchema(schemaVersion)
        }
        let revisionID = try container.decode(String.self, forKey: .revisionID)
        let ssid = try container.decode(String.self, forKey: .ssid)
        let wifiDevice = try container.decodeIfPresent(String.self, forKey: .wifiDevice)
        let credentialReference = try container.decode(String.self, forKey: .credentialReference)
        try self.init(
            revisionID: revisionID,
            ssid: ssid,
            wifiDevice: wifiDevice,
            credentialReference: credentialReference
        )
    }

    public static func validateSSID(_ ssid: String) throws {
        let byteCount = ssid.lengthOfBytes(using: .utf8)
        guard (1...32).contains(byteCount) else {
            throw HotspotConfigurationError.invalidSSIDByteCount(byteCount)
        }
    }

    public static func validateWiFiDevice(_ device: String?) throws {
        guard let device else { return }
        guard !device.isEmpty,
              device.count <= 32,
              device.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$"#,
                options: .regularExpression
              ) != nil else {
            throw HotspotConfigurationError.invalidWiFiDevice(device)
        }
    }

    public func hasExactSSID(_ candidate: String) -> Bool {
        ssid.hasExactUTF8Representation(as: candidate)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.revisionID == rhs.revisionID
            && lhs.ssid.hasExactUTF8Representation(as: rhs.ssid)
            && lhs.wifiDevice == rhs.wifiDevice
            && lhs.credentialReference == rhs.credentialReference
    }
}

public enum HotspotConfigurationSavePhase: String, Codable, Sendable {
    case prepared
    case credentialStaged = "credential_staged"
    case pointerCommitted = "pointer_committed"
    case cleanupPending = "cleanup_pending"
}

public struct HotspotConfigurationSaveJournal: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var phase: HotspotConfigurationSavePhase
    public var candidate: HotspotConfigurationRevision
    public var previousRevision: HotspotConfigurationRevision?
    public var cleanupCredentialReference: String?

    public init(
        phase: HotspotConfigurationSavePhase,
        candidate: HotspotConfigurationRevision,
        previousRevision: HotspotConfigurationRevision?,
        cleanupCredentialReference: String? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.phase = phase
        self.candidate = candidate
        self.previousRevision = previousRevision
        self.cleanupCredentialReference = cleanupCredentialReference
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case phase
        case candidate
        case previousRevision = "previous_revision"
        case cleanupCredentialReference = "cleanup_credential_reference"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw HotspotConfigurationError.unsupportedSchema(schemaVersion)
        }
        let phase = try container.decode(HotspotConfigurationSavePhase.self, forKey: .phase)
        let candidate = try container.decode(
            HotspotConfigurationRevision.self,
            forKey: .candidate
        )
        let previousRevision = try container.decodeIfPresent(
            HotspotConfigurationRevision.self,
            forKey: .previousRevision
        )
        let cleanupCredentialReference = try container.decodeIfPresent(
            String.self,
            forKey: .cleanupCredentialReference
        )
        if phase == .cleanupPending,
           cleanupCredentialReference?.isEmpty != false {
            throw HotspotConfigurationError.invalidCredentialReference
        }
        self.init(
            phase: phase,
            candidate: candidate,
            previousRevision: previousRevision,
            cleanupCredentialReference: cleanupCredentialReference
        )
    }
}

public enum HotspotConfigurationCheckpoint: String, Sendable {
    case prepared
    case credentialStaged = "credential_staged"
    case pointerCommitted = "pointer_committed"
    case cleanupPending = "cleanup_pending"
    case journalCleared = "journal_cleared"
}

public protocol HotspotConfigurationCheckpointObserving: Sendable {
    func reached(
        _ checkpoint: HotspotConfigurationCheckpoint,
        journal: HotspotConfigurationSaveJournal?
    )
}

public struct NoOpHotspotConfigurationCheckpointObserver:
    HotspotConfigurationCheckpointObserving {
    public init() {}

    public func reached(
        _ checkpoint: HotspotConfigurationCheckpoint,
        journal: HotspotConfigurationSaveJournal?
    ) {}
}

public enum HotspotConfigurationError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidRevisionID
    case invalidSSIDByteCount(Int)
    case invalidWiFiDevice(String)
    case invalidCredentialReference
    case passwordRequired
    case noActiveConfiguration
    case credentialMissing(String)
    case credentialStageFailed(String)
    case credentialReadbackMismatch
    case persistenceFailed(String)
    case cleanupPending(String)
    case cleanupFailed(String)
    case legacyMigrationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "Unsupported hotspot configuration schema version: \(version)."
        case .invalidRevisionID:
            "The hotspot configuration revision ID is invalid."
        case .invalidSSIDByteCount(let count):
            "The hotspot SSID must be between 1 and 32 UTF-8 bytes; received \(count)."
        case .invalidWiFiDevice(let device):
            "The Wi-Fi device name '\(device)' is invalid."
        case .invalidCredentialReference:
            "The hotspot credential reference is invalid."
        case .passwordRequired:
            "A password is required for a new or changed hotspot SSID."
        case .noActiveConfiguration:
            "No committed hotspot configuration is available."
        case .credentialMissing(let reference):
            "The committed hotspot credential '\(reference)' is missing."
        case .credentialStageFailed(let detail):
            "The hotspot credential could not be staged: \(detail)"
        case .credentialReadbackMismatch:
            "The staged hotspot credential could not be verified."
        case .persistenceFailed(let detail):
            "The hotspot configuration could not be persisted: \(detail)"
        case .cleanupPending(let detail):
            "A previous hotspot configuration cleanup is still pending: \(detail)"
        case .cleanupFailed(let detail):
            "The committed hotspot configuration is active, but cleanup failed: \(detail)"
        case .legacyMigrationFailed(let detail):
            "The legacy hotspot configuration could not be migrated: \(detail)"
        }
    }
}
