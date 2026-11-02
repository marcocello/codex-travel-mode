import CodexTravelModeCore
import CryptoKit
import Darwin
import Foundation

public enum HotspotConfigurationProofSupportError: LocalizedError {
    case invalidPrivateRoot
    case unreadablePasswordFile
    case corruptVault
    case missingCheckpointMarker

    public var errorDescription: String? {
        switch self {
        case .invalidPrivateRoot:
            "The proof credential vault must be inside the declared private root."
        case .unreadablePasswordFile:
            "The proof password file is missing or is not valid UTF-8."
        case .corruptVault:
            "The proof credential vault could not be decoded."
        case .missingCheckpointMarker:
            "A checkpoint marker path is required when a blocking checkpoint is selected."
        }
    }
}

public struct HotspotProofOperation: Codable, Equatable, Sendable {
    public let sequence: Int
    public let launchID: String
    public let pid: Int32
    public let operation: String
    public let credentialReference: String?
    public let fingerprint: String?

    public init(
        sequence: Int,
        launchID: String,
        pid: Int32,
        operation: String,
        credentialReference: String? = nil,
        fingerprint: String? = nil
    ) {
        self.sequence = sequence
        self.launchID = launchID
        self.pid = pid
        self.operation = operation
        self.credentialReference = credentialReference
        self.fingerprint = fingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case sequence
        case launchID = "launch_id"
        case pid
        case operation
        case credentialReference = "credential_reference"
        case fingerprint
    }
}

public struct HotspotProofTraceDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var operations: [HotspotProofOperation]

    public init(schemaVersion: Int = 1, operations: [HotspotProofOperation] = []) {
        self.schemaVersion = schemaVersion
        self.operations = operations
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case operations
    }
}

public final class DurableRedactedHotspotProofTrace: @unchecked Sendable {
    public let fileURL: URL

    private let launchID: String
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        fileURL: URL,
        launchID: String,
        fileManager: FileManager = FileManager()
    ) throws {
        self.fileURL = fileURL
        self.launchID = launchID
        self.fileManager = fileManager
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    public func record(
        _ operation: String,
        credentialReference: String? = nil,
        fingerprint: String? = nil
    ) throws {
        try locked {
            var document = try loadUnlocked()
            document.operations.append(
                HotspotProofOperation(
                    sequence: document.operations.count + 1,
                    launchID: launchID,
                    pid: getpid(),
                    operation: operation,
                    credentialReference: credentialReference,
                    fingerprint: fingerprint
                )
            )
            try DurableHotspotProofFile.writeJSON(document, to: fileURL)
        }
    }

    public func read() throws -> HotspotProofTraceDocument {
        try locked { try loadUnlocked() }
    }

    private func loadUnlocked() throws -> HotspotProofTraceDocument {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return HotspotProofTraceDocument()
        }
        return try DurableHotspotProofFile.decode(
            HotspotProofTraceDocument.self,
            from: fileURL
        )
    }

    private func locked<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

public struct HotspotProofCredentialInventoryItem: Codable, Equatable, Sendable {
    public let credentialReference: String
    public let fingerprint: String

    public init(credentialReference: String, fingerprint: String) {
        self.credentialReference = credentialReference
        self.fingerprint = fingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case credentialReference = "credential_reference"
        case fingerprint
    }
}

public enum HotspotProofFault: String, Codable, Equatable, Sendable {
    case credentialStageFailure = "credential_stage_failure"
    case credentialVerificationMismatch = "credential_verification_mismatch"
    case credentialVerificationReadFailure = "credential_verification_read_failure"
    case activePointerPrecommitFailure = "active_pointer_precommit_failure"
    case activePointerAmbiguousFailure = "active_pointer_ambiguous_failure"
    case cleanupDeletionFailure = "cleanup_deletion_failure"
}

public final class DurableRecordingHotspotCredentialStore:
    KeychainPasswordStoring,
    @unchecked Sendable {
    public let privateRootURL: URL
    public let vaultURL: URL

    private struct Vault: Codable {
        var schemaVersion = 1
        var credentials: [String: Data] = [:]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case credentials
        }
    }

    private let trace: DurableRedactedHotspotProofTrace
    private let fault: HotspotProofFault?
    private let fileManager: FileManager
    private let lock = NSLock()
    private var verificationFaultAccount: String?
    private var didConsumeVerificationFault = false

    public init(
        privateRootURL: URL,
        trace: DurableRedactedHotspotProofTrace,
        fault: HotspotProofFault? = nil,
        fileManager: FileManager = FileManager()
    ) throws {
        self.privateRootURL = privateRootURL.standardizedFileURL
        self.vaultURL = self.privateRootURL.appendingPathComponent(
            "credential-vault.json",
            isDirectory: false
        )
        self.trace = trace
        self.fault = fault
        self.fileManager = fileManager
        try fileManager.createDirectory(
            at: self.privateRootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: self.privateRootURL.path
        )
    }

    public func readPassword(account: String) throws -> String {
        try locked {
            let vault = try loadVault()
            guard let passwordData = vault.credentials[account] else {
                try trace.record("credential_read_missing", credentialReference: account)
                throw KeychainError.notFound
            }
            guard let password = String(data: passwordData, encoding: .utf8) else {
                throw KeychainError.invalidPasswordData
            }
            if account == verificationFaultAccount, !didConsumeVerificationFault {
                didConsumeVerificationFault = true
                switch fault {
                case .credentialVerificationMismatch:
                    try trace.record(
                        "credential_verification_mismatch",
                        credentialReference: account,
                        fingerprint: Self.fingerprint(passwordData)
                    )
                    return password + "\u{0}"
                case .credentialVerificationReadFailure:
                    try trace.record(
                        "credential_verification_read_failure",
                        credentialReference: account
                    )
                    throw KeychainError.readFailed(-25293)
                default:
                    break
                }
            }
            try trace.record(
                "credential_read",
                credentialReference: account,
                fingerprint: Self.fingerprint(passwordData)
            )
            return password
        }
    }

    public func savePassword(_ password: String, account: String) throws {
        guard !password.isEmpty else { throw KeychainError.emptyPassword }
        try locked {
            if fault == .credentialStageFailure {
                try trace.record(
                    "credential_stage_failure",
                    credentialReference: account
                )
                throw KeychainError.saveFailed(-1)
            }
            var vault = try loadVault()
            let passwordData = Data(password.utf8)
            if let existing = vault.credentials[account], existing != passwordData {
                throw KeychainError.credentialConflict
            }
            vault.credentials[account] = passwordData
            try persist(vault)
            if fault == .credentialVerificationMismatch
                || fault == .credentialVerificationReadFailure {
                verificationFaultAccount = account
            }
            try trace.record(
                "credential_stage",
                credentialReference: account,
                fingerprint: Self.fingerprint(passwordData)
            )
        }
    }

    public func passwordExists(account: String) throws -> Bool {
        try locked {
            let exists = try loadVault().credentials[account] != nil
            try trace.record(
                exists ? "credential_exists" : "credential_missing",
                credentialReference: account
            )
            return exists
        }
    }

    public func deletePassword(account: String) throws {
        try locked {
            if fault == .cleanupDeletionFailure {
                try trace.record(
                    "credential_cleanup_failure",
                    credentialReference: account
                )
                throw KeychainError.deleteFailed(-1)
            }
            var vault = try loadVault()
            vault.credentials.removeValue(forKey: account)
            try persist(vault)
            try trace.record("credential_cleanup", credentialReference: account)
        }
    }

    public func inventory() throws -> [HotspotProofCredentialInventoryItem] {
        try locked {
            try loadVault().credentials
                .map { reference, passwordData in
                    HotspotProofCredentialInventoryItem(
                        credentialReference: reference,
                        fingerprint: Self.fingerprint(passwordData)
                    )
                }
                .sorted { $0.credentialReference < $1.credentialReference }
        }
    }

    public static func fingerprint(_ password: String) -> String {
        fingerprint(Data(password.utf8))
    }

    public static func fingerprint(_ passwordData: Data) -> String {
        SHA256.hash(data: passwordData)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func loadVault() throws -> Vault {
        guard fileManager.fileExists(atPath: vaultURL.path) else { return Vault() }
        do {
            return try DurableHotspotProofFile.decode(Vault.self, from: vaultURL)
        } catch {
            throw HotspotConfigurationProofSupportError.corruptVault
        }
    }

    private func persist(_ vault: Vault) throws {
        try DurableHotspotProofFile.writeJSON(vault, to: vaultURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: vaultURL.path
        )
    }

    private func locked<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

public final class FaultInjectingHotspotConfigurationStore:
    HotspotConfigurationPersisting,
    @unchecked Sendable {
    private let base: any HotspotConfigurationPersisting
    private let fault: HotspotProofFault?
    private let trace: DurableRedactedHotspotProofTrace
    private let lock = NSLock()
    private var didInjectPointerFault = false

    public init(
        base: any HotspotConfigurationPersisting,
        fault: HotspotProofFault?,
        trace: DurableRedactedHotspotProofTrace
    ) {
        self.base = base
        self.fault = fault
        self.trace = trace
    }

    public func loadActive() throws -> HotspotConfigurationRevision? {
        try base.loadActive()
    }

    public func writeActive(_ revision: HotspotConfigurationRevision) throws {
        let injectedFault = takePointerFault()
        switch injectedFault {
        case .activePointerPrecommitFailure:
            try trace.record(
                "active_pointer_precommit_failure",
                credentialReference: revision.credentialReference
            )
            throw HotspotConfigurationFileError.writeFailed(
                path: "active.json",
                detail: "injected precommit failure"
            )
        case .activePointerAmbiguousFailure:
            try base.writeActive(revision)
            try trace.record(
                "active_pointer_ambiguous_failure",
                credentialReference: revision.credentialReference
            )
            throw HotspotConfigurationFileError.writeFailed(
                path: "active.json",
                detail: "injected post-write ambiguous failure"
            )
        default:
            try base.writeActive(revision)
        }
    }

    public func loadSaveJournal() throws -> HotspotConfigurationSaveJournal? {
        try base.loadSaveJournal()
    }

    public func writeSaveJournal(_ journal: HotspotConfigurationSaveJournal) throws {
        try base.writeSaveJournal(journal)
    }

    public func clearSaveJournal() throws {
        try base.clearSaveJournal()
    }

    private func takePointerFault() -> HotspotProofFault? {
        lock.lock()
        defer { lock.unlock() }
        guard !didInjectPointerFault,
              (fault == .activePointerPrecommitFailure
                || fault == .activePointerAmbiguousFailure) else {
            return nil
        }
        didInjectPointerFault = true
        return fault
    }
}

public struct HotspotProofCheckpointMarker: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let launchID: String
    public let pid: Int32
    public let boundary: String
    public let checkpoint: String
    public let journal: HotspotConfigurationSaveJournal?

    public init(
        launchID: String,
        pid: Int32,
        boundary: String,
        checkpoint: String,
        journal: HotspotConfigurationSaveJournal?
    ) {
        self.schemaVersion = 1
        self.launchID = launchID
        self.pid = pid
        self.boundary = boundary
        self.checkpoint = checkpoint
        self.journal = journal
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case launchID = "launch_id"
        case pid
        case boundary
        case checkpoint
        case journal
    }
}

public final class DurableBlockingHotspotCheckpointObserver:
    HotspotConfigurationCheckpointObserving,
    @unchecked Sendable {
    private let selectedCheckpoint: String?
    private let selectedBoundary: String?
    private let markerURL: URL?
    private let gateURL: URL?
    private let launchID: String
    private let trace: DurableRedactedHotspotProofTrace
    private let fileManager: FileManager
    private let lock = NSLock()
    private var didBlock = false

    public init(
        selectedCheckpoint: HotspotConfigurationCheckpoint?,
        selectedBoundary: String?,
        markerURL: URL?,
        gateURL: URL?,
        launchID: String,
        trace: DurableRedactedHotspotProofTrace,
        fileManager: FileManager = FileManager()
    ) throws {
        if selectedCheckpoint != nil, markerURL == nil {
            throw HotspotConfigurationProofSupportError.missingCheckpointMarker
        }
        self.selectedCheckpoint = selectedCheckpoint?.rawValue
        self.selectedBoundary = selectedBoundary
        self.markerURL = markerURL
        self.gateURL = gateURL
        self.launchID = launchID
        self.trace = trace
        self.fileManager = fileManager
    }

    public func reached(
        _ checkpoint: HotspotConfigurationCheckpoint,
        journal: HotspotConfigurationSaveJournal?
    ) {
        do {
            try trace.record(
                "checkpoint_\(checkpoint.rawValue)",
                credentialReference: journal?.candidate.credentialReference
            )
            guard checkpoint.rawValue == selectedCheckpoint else { return }

            lock.lock()
            let shouldBlock = !didBlock
            didBlock = true
            lock.unlock()
            guard shouldBlock, let markerURL else { return }

            let marker = HotspotProofCheckpointMarker(
                launchID: launchID,
                pid: getpid(),
                boundary: selectedBoundary ?? checkpoint.rawValue,
                checkpoint: checkpoint.rawValue,
                journal: journal
            )
            try DurableHotspotProofFile.writeJSON(marker, to: markerURL)
            waitForParentReleaseOrTermination()
        } catch {
            let message = "hotspot proof checkpoint persistence failed\n"
            FileHandle.standardError.write(Data(message.utf8))
            Darwin._exit(74)
        }
    }

    private func waitForParentReleaseOrTermination() {
        while true {
            if let gateURL,
               fileManager.fileExists(atPath: gateURL.path) {
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}

public struct HotspotProofLoadedSettings: Codable, Equatable, Sendable {
    public let hotspotSSID: String
    public let wifiDevice: String?

    public init(hotspotSSID: String, wifiDevice: String?) {
        self.hotspotSSID = hotspotSSID
        self.wifiDevice = wifiDevice
    }

    private enum CodingKeys: String, CodingKey {
        case hotspotSSID = "hotspot_ssid"
        case wifiDevice = "wifi_device"
    }
}

public struct HotspotConfigurationWorkerReadback: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let launchID: String
    public let pid: Int32
    public let action: String
    public let injectedFault: HotspotProofFault?
    public let errorCategory: String?
    public let loadedSettings: HotspotProofLoadedSettings
    public let activeRevision: HotspotConfigurationRevision?
    public let saveJournal: HotspotConfigurationSaveJournal?
    public let credentialInventory: [HotspotProofCredentialInventoryItem]
    public let operations: [HotspotProofOperation]

    public init(
        launchID: String,
        pid: Int32,
        action: String,
        injectedFault: HotspotProofFault?,
        errorCategory: String?,
        loadedSettings: HotspotProofLoadedSettings,
        activeRevision: HotspotConfigurationRevision?,
        saveJournal: HotspotConfigurationSaveJournal?,
        credentialInventory: [HotspotProofCredentialInventoryItem],
        operations: [HotspotProofOperation]
    ) {
        self.schemaVersion = 1
        self.launchID = launchID
        self.pid = pid
        self.action = action
        self.injectedFault = injectedFault
        self.errorCategory = errorCategory
        self.loadedSettings = loadedSettings
        self.activeRevision = activeRevision
        self.saveJournal = saveJournal
        self.credentialInventory = credentialInventory
        self.operations = operations
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case launchID = "launch_id"
        case pid
        case action
        case injectedFault = "injected_fault"
        case errorCategory = "error_category"
        case loadedSettings = "loaded_settings"
        case activeRevision = "active_revision"
        case saveJournal = "save_journal"
        case credentialInventory = "credential_inventory"
        case operations
    }
}

public enum DurableHotspotProofFile {
    public static func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    public static func decode<Value: Decodable>(
        _ type: Value.Type,
        from url: URL
    ) throws -> Value {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    public static func readExactPassword(
        from passwordFileURL: URL,
        privateRootURL: URL
    ) throws -> String {
        let file = passwordFileURL.resolvingSymlinksInPath().standardizedFileURL
        let root = privateRootURL.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(prefix),
              let password = String(data: try Data(contentsOf: file), encoding: .utf8) else {
            throw HotspotConfigurationProofSupportError.unreadablePasswordFile
        }
        return password
    }
}
