import Foundation

public final class FileTravelSettingsStore: TravelSettingsStoring, @unchecked Sendable {
    private static let legacySSIDKey = "fallbackHotspotSSID"
    private static let legacyWiFiDeviceKey = "wifiDevice"
    private static let legacyPasswordSavedKey = "fallbackHotspotPasswordSaved"
    private static let legacyPasswordAccount = "fallbackHotspotPassword"
    private static let credentialPrefix = "hotspot-configuration."

    private let defaults: UserDefaults
    private let keychain: any KeychainPasswordStoring
    private let persistence: any HotspotConfigurationPersisting
    private let checkpointObserver: any HotspotConfigurationCheckpointObserving
    private let lock = NSLock()
    private var initializationError: (any Error)?

    public convenience init(
        rootURL: URL = FileHotspotConfigurationStore.defaultRootURL,
        defaults: UserDefaults = .standard,
        keychain: any KeychainPasswordStoring = KeychainPasswordStore(),
        checkpointObserver: any HotspotConfigurationCheckpointObserving =
            NoOpHotspotConfigurationCheckpointObserver()
    ) {
        self.init(
            defaults: defaults,
            keychain: keychain,
            configurationStore: FileHotspotConfigurationStore(rootURL: rootURL),
            checkpointObserver: checkpointObserver
        )
    }

    public init(
        defaults: UserDefaults,
        keychain: any KeychainPasswordStoring,
        configurationStore: any HotspotConfigurationPersisting,
        checkpointObserver: any HotspotConfigurationCheckpointObserving =
            NoOpHotspotConfigurationCheckpointObserver()
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.persistence = configurationStore
        self.checkpointObserver = checkpointObserver
        initialize()
    }

    public var lastRecoveryError: (any Error)? {
        locked { initializationError }
    }

    public func load() -> TravelModeSettings {
        locked {
            if let active = try? persistence.loadActive() {
                return settings(from: active)
            }
            return TravelModeSettings()
        }
    }

    public func hasSavedHotspotPassword() -> Bool {
        locked {
            if let active = try? persistence.loadActive() {
                return (try? keychain.passwordExists(account: active.credentialReference)) == true
            }
            return (try? legacyConfigurationIsComplete()) == true
        }
    }

    public func loadHotspotPassword() throws -> String {
        try locked {
            if let active = try persistence.loadActive() {
                do {
                    return try keychain.readPassword(account: active.credentialReference)
                } catch KeychainError.notFound {
                    throw HotspotConfigurationError.credentialMissing(active.credentialReference)
                }
            }
            guard try legacyConfigurationIsComplete() else {
                throw HotspotConfigurationError.noActiveConfiguration
            }
            return try keychain.readPassword(account: Self.legacyPasswordAccount)
        }
    }

    public func loadHotspotPassword(credentialReference: String) throws -> String {
        try locked {
            do {
                return try keychain.readPassword(account: credentialReference)
            } catch KeychainError.notFound {
                throw HotspotConfigurationError.credentialMissing(credentialReference)
            }
        }
    }

    public func save(_ settings: TravelModeSettings) throws {
        try locked {
            if try persistence.loadSaveJournal() != nil {
                try recoverLocked()
            }
            if let journal = try persistence.loadSaveJournal() {
                throw HotspotConfigurationError.cleanupPending(
                    "save-journal.json remains in phase \(journal.phase.rawValue) after recovery"
                )
            }
            try commitLocked(settings: settings)
            initializationError = nil
        }
    }

    public func recoverHotspotConfiguration() throws {
        try locked {
            do {
                try recoverLocked()
                try migrateLegacyIfNeededLocked()
                removeMigratedLegacyDefaultsIfSafe()
                initializationError = nil
            } catch {
                initializationError = error
                throw error
            }
        }
    }

    public func activeHotspotConfiguration() throws -> HotspotConfigurationRevision? {
        try locked { try persistence.loadActive() }
    }

    public func legacyHotspotDraft() -> TravelModeSettings? {
        locked {
            guard (try? persistence.loadActive()) == nil else { return nil }
            let draft = legacySettings()
            guard !draft.hotspotSSID.isEmpty || !draft.wifiDevice.isEmpty else { return nil }
            return draft
        }
    }
}

public typealias UserDefaultsTravelSettingsStore = FileTravelSettingsStore

private enum ActivePointerCommitResolutionError: Error {
    case notCommitted(String)
    case indeterminate(String)
}

private extension FileTravelSettingsStore {
    func initialize() {
        lock.lock()
        defer { lock.unlock() }
        do {
            try recoverLocked()
            try migrateLegacyIfNeededLocked()
            removeMigratedLegacyDefaultsIfSafe()
        } catch {
            initializationError = error
        }
    }

    func commitLocked(
        settings: TravelModeSettings,
        cleanupCredentialReference: String? = nil
    ) throws {
        let previous = try persistence.loadActive()
        let wifiDevice = try normalizedWiFiDevice(settings.wifiDevice)
        let password = settings.hotspotPassword
        let reusesCredential = password.isEmpty

        let credentialReference: String
        if reusesCredential {
            guard let previous, previous.hasExactSSID(settings.hotspotSSID) else {
                throw HotspotConfigurationError.passwordRequired
            }
            guard try keychain.passwordExists(account: previous.credentialReference) else {
                throw HotspotConfigurationError.credentialMissing(previous.credentialReference)
            }
            credentialReference = previous.credentialReference
        } else {
            credentialReference = Self.credentialPrefix + UUID().uuidString
        }

        let candidate = try HotspotConfigurationRevision(
            ssid: settings.hotspotSSID,
            wifiDevice: wifiDevice,
            credentialReference: credentialReference
        )
        if reusesCredential,
           previous?.hasExactSSID(candidate.ssid) == true,
           previous?.wifiDevice == candidate.wifiDevice {
            return
        }

        let supersededReference = previous?.credentialReference == candidate.credentialReference
            ? nil
            : previous?.credentialReference
        var journal = HotspotConfigurationSaveJournal(
            phase: .prepared,
            candidate: candidate,
            previousRevision: previous,
            cleanupCredentialReference: cleanupCredentialReference ?? supersededReference
        )
        try persist(journal)
        checkpointObserver.reached(.prepared, journal: journal)

        if !reusesCredential {
            do {
                try stageAndVerify(password: password, reference: credentialReference)
            } catch {
                try rollbackUncommitted(journal: &journal, deletesCandidate: true)
                throw error
            }
            journal.phase = .credentialStaged
            try persist(journal)
            checkpointObserver.reached(.credentialStaged, journal: journal)
        }

        do {
            try commitActive(candidate)
        } catch ActivePointerCommitResolutionError.notCommitted(let detail) {
            try rollbackUncommitted(journal: &journal, deletesCandidate: !reusesCredential)
            throw HotspotConfigurationError.persistenceFailed(detail)
        } catch ActivePointerCommitResolutionError.indeterminate(let detail) {
            throw HotspotConfigurationError.persistenceFailed(detail)
        } catch {
            throw error
        }

        journal.phase = .pointerCommitted
        do {
            try persist(journal)
        } catch {
            guard (try? persistence.loadActive()) == candidate else { throw error }
        }
        checkpointObserver.reached(.pointerCommitted, journal: journal)
        try finishCommitted(
            journal: &journal,
            explicitCleanupReference: cleanupCredentialReference
        )
    }

    func stageAndVerify(password: String, reference: String) throws {
        do {
            try keychain.savePassword(password, account: reference)
        } catch let stageError {
            do {
                let readback = try keychain.readPassword(account: reference)
                guard readback.hasExactUTF8Representation(as: password) else {
                    throw HotspotConfigurationError.credentialStageFailed(
                        stageError.localizedDescription
                    )
                }
            } catch KeychainError.notFound {
                throw HotspotConfigurationError.credentialStageFailed(
                    stageError.localizedDescription
                )
            }
        }
        guard try keychain.readPassword(account: reference)
            .hasExactUTF8Representation(as: password) else {
            throw HotspotConfigurationError.credentialReadbackMismatch
        }
    }

    func commitActive(_ candidate: HotspotConfigurationRevision) throws {
        do {
            try persistence.writeActive(candidate)
        } catch let writeError {
            do {
                let active = try persistence.loadActive()
                guard active == candidate else {
                    throw ActivePointerCommitResolutionError.notCommitted(
                        writeError.localizedDescription
                    )
                }
            } catch let resolution as ActivePointerCommitResolutionError {
                throw resolution
            } catch let readbackError {
                throw ActivePointerCommitResolutionError.indeterminate(
                    "active-pointer write failed and read-back was unavailable: "
                        + "\(writeError.localizedDescription); \(readbackError.localizedDescription)"
                )
            }
        }
    }

    func finishCommitted(
        journal: inout HotspotConfigurationSaveJournal,
        explicitCleanupReference: String?
    ) throws {
        let previousReference = journal.previousRevision?.credentialReference
        let inferredSupersededReference = previousReference == journal.candidate.credentialReference
            ? nil
            : previousReference
        guard let cleanupReference = explicitCleanupReference
            ?? journal.cleanupCredentialReference
            ?? inferredSupersededReference else {
            try clearJournal()
            return
        }
        journal.phase = .cleanupPending
        journal.cleanupCredentialReference = cleanupReference
        try persist(journal)
        checkpointObserver.reached(.cleanupPending, journal: journal)
        do {
            try deleteJournalNamedCredential(cleanupReference, journal: journal)
            try clearJournal()
        } catch {
            throw HotspotConfigurationError.cleanupFailed(error.localizedDescription)
        }
    }

    func rollbackUncommitted(
        journal: inout HotspotConfigurationSaveJournal,
        deletesCandidate: Bool
    ) throws {
        guard deletesCandidate else {
            try clearJournal()
            return
        }
        journal.phase = .cleanupPending
        journal.cleanupCredentialReference = journal.candidate.credentialReference
        try persist(journal)
        checkpointObserver.reached(.cleanupPending, journal: journal)
        do {
            try deleteJournalNamedCredential(journal.candidate.credentialReference, journal: journal)
            try clearJournal()
        } catch {
            throw HotspotConfigurationError.cleanupFailed(error.localizedDescription)
        }
    }
}

private extension FileTravelSettingsStore {
    func recoverLocked() throws {
        guard var journal = try persistence.loadSaveJournal() else { return }
        let active = try persistence.loadActive()
        switch journal.phase {
        case .prepared, .credentialStaged:
            if active == journal.candidate {
                journal.phase = .pointerCommitted
                try persist(journal)
                checkpointObserver.reached(.pointerCommitted, journal: journal)
                try finishCommitted(journal: &journal, explicitCleanupReference: nil)
            } else {
                let candidateIsNew = journal.previousRevision?.credentialReference
                    != journal.candidate.credentialReference
                try rollbackUncommitted(journal: &journal, deletesCandidate: candidateIsNew)
            }
        case .pointerCommitted:
            guard active == journal.candidate else {
                let candidateIsNew = journal.previousRevision?.credentialReference
                    != journal.candidate.credentialReference
                try rollbackUncommitted(journal: &journal, deletesCandidate: candidateIsNew)
                return
            }
            try finishCommitted(journal: &journal, explicitCleanupReference: nil)
        case .cleanupPending:
            guard let reference = journal.cleanupCredentialReference else {
                throw HotspotConfigurationError.persistenceFailed(
                    "cleanup_pending journal has no credential reference"
                )
            }
            do {
                try deleteJournalNamedCredential(reference, journal: journal)
                try clearJournal()
            } catch {
                throw HotspotConfigurationError.cleanupFailed(error.localizedDescription)
            }
        }
    }

    func deleteJournalNamedCredential(
        _ reference: String,
        journal: HotspotConfigurationSaveJournal
    ) throws {
        let journalReferences = Set(
            [
                journal.candidate.credentialReference,
                journal.previousRevision?.credentialReference,
                journal.cleanupCredentialReference
            ].compactMap { $0 }
        )
        guard journalReferences.contains(reference) else {
            throw HotspotConfigurationError.persistenceFailed(
                "cleanup attempted a credential not named by the save journal"
            )
        }
        if try persistence.loadActive()?.credentialReference == reference {
            throw HotspotConfigurationError.persistenceFailed(
                "cleanup refused to delete the active credential"
            )
        }
        try keychain.deletePassword(account: reference)
    }

    func persist(_ journal: HotspotConfigurationSaveJournal) throws {
        do {
            try persistence.writeSaveJournal(journal)
        } catch {
            guard (try? persistence.loadSaveJournal()) == journal else {
                throw HotspotConfigurationError.persistenceFailed(error.localizedDescription)
            }
        }
    }

    func clearJournal() throws {
        do {
            try persistence.clearSaveJournal()
        } catch {
            throw HotspotConfigurationError.persistenceFailed(error.localizedDescription)
        }
        checkpointObserver.reached(.journalCleared, journal: nil)
    }
}

private extension FileTravelSettingsStore {
    func migrateLegacyIfNeededLocked() throws {
        guard try persistence.loadActive() == nil else { return }
        let ssid = defaults.string(forKey: Self.legacySSIDKey) ?? ""
        guard (try? HotspotConfigurationRevision.validateSSID(ssid)) != nil else { return }
        guard try keychain.passwordExists(account: Self.legacyPasswordAccount) else {
            return
        }
        let password = try keychain.readPassword(account: Self.legacyPasswordAccount)
        guard !password.isEmpty else { return }
        let legacyDevice = defaults.string(forKey: Self.legacyWiFiDeviceKey) ?? ""
        let device = (try? normalizedWiFiDevice(legacyDevice)) ?? nil
        try commitLocked(
            settings: TravelModeSettings(
                hotspotSSID: ssid,
                hotspotPassword: password,
                wifiDevice: device ?? ""
            ),
            cleanupCredentialReference: Self.legacyPasswordAccount
        )
    }

    func removeMigratedLegacyDefaultsIfSafe() {
        guard (try? persistence.loadActive()) != nil,
              (try? keychain.passwordExists(account: Self.legacyPasswordAccount)) == false else {
            return
        }
        defaults.removeObject(forKey: Self.legacySSIDKey)
        defaults.removeObject(forKey: Self.legacyWiFiDeviceKey)
        defaults.removeObject(forKey: Self.legacyPasswordSavedKey)
    }

    func legacyConfigurationIsComplete() throws -> Bool {
        let ssid = defaults.string(forKey: Self.legacySSIDKey) ?? ""
        guard (try? HotspotConfigurationRevision.validateSSID(ssid)) != nil else { return false }
        return try keychain.passwordExists(account: Self.legacyPasswordAccount)
    }

    func legacySettings() -> TravelModeSettings {
        TravelModeSettings(
            hotspotSSID: defaults.string(forKey: Self.legacySSIDKey) ?? "",
            hotspotPassword: "",
            wifiDevice: defaults.string(forKey: Self.legacyWiFiDeviceKey) ?? ""
        )
    }

    func settings(from revision: HotspotConfigurationRevision) -> TravelModeSettings {
        TravelModeSettings(
            hotspotSSID: revision.ssid,
            hotspotPassword: "",
            wifiDevice: revision.wifiDevice ?? ""
        )
    }

    func normalizedWiFiDevice(_ value: String) throws -> String? {
        if value.isEmpty { return nil }
        try HotspotConfigurationRevision.validateWiFiDevice(value)
        return value
    }

    func locked<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
