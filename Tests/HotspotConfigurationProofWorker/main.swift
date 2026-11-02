import CodexTravelModeCore
import Darwin
import Foundation
import HotspotConfigurationProofSupport

private enum WorkerAction: String {
    case seed
    case save
    case recover
    case inspect
    case legacyMigration = "legacy-migration"
}

private struct CheckpointSelection {
    let checkpoint: HotspotConfigurationCheckpoint
    let boundary: String

    init(argument: String) throws {
        let normalized = argument.replacingOccurrences(of: "-", with: "_")
        switch normalized {
        case "before_staging", "prepared":
            checkpoint = .prepared
            boundary = "before_staging"
        case "after_verified_staging", "credential_staged":
            checkpoint = .credentialStaged
            boundary = "after_verified_staging"
        case "after_pointer_commit", "pointer_committed":
            checkpoint = .pointerCommitted
            boundary = "after_pointer_commit"
        case "during_cleanup", "cleanup_pending":
            checkpoint = .cleanupPending
            boundary = "during_cleanup"
        default:
            throw WorkerError.unsupportedCheckpoint(argument)
        }
    }
}

private struct WorkerArguments {
    let action: WorkerAction
    let workspaceURL: URL
    let privateRootURL: URL
    let launchID: String
    let ssid: String?
    let wifiDevice: String
    let passwordFileURL: URL?
    let fault: HotspotProofFault?
    let checkpoint: CheckpointSelection?
    let checkpointMarkerURL: URL?
    let checkpointGateURL: URL?
    let readbackURL: URL

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count,
                  arguments[index].hasPrefix("--") else {
                throw WorkerError.invalidArguments
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }

        guard let actionValue = values["--action"],
              let action = WorkerAction(rawValue: actionValue),
              let workspace = values["--workspace"],
              let privateRoot = values["--private-root"],
              let launchID = values["--launch-id"],
              !launchID.isEmpty else {
            throw WorkerError.invalidArguments
        }

        let workspaceURL = URL(fileURLWithPath: workspace, isDirectory: true)
            .standardizedFileURL
        let privateRootURL = URL(fileURLWithPath: privateRoot, isDirectory: true)
            .standardizedFileURL
        guard privateRootURL.lastPathComponent == "private" else {
            throw HotspotConfigurationProofSupportError.invalidPrivateRoot
        }

        let checkpoint = try values["--checkpoint"].map(CheckpointSelection.init)
        if checkpoint != nil, action != .save {
            throw WorkerError.checkpointRequiresSave
        }
        let fault = try values["--fault"].map { value in
            let normalized = value.replacingOccurrences(of: "-", with: "_")
            guard let fault = HotspotProofFault(rawValue: normalized) else {
                throw WorkerError.unsupportedFault(value)
            }
            return fault
        }
        if fault != nil, action != .save {
            throw WorkerError.faultRequiresSave
        }

        let ssid = values["--ssid"]
        let passwordFileURL = values["--password-file"].map {
            URL(fileURLWithPath: $0, isDirectory: false)
        }
        if action == .seed || action == .save || action == .legacyMigration {
            guard ssid != nil, passwordFileURL != nil else {
                throw WorkerError.saveArgumentsMissing
            }
        }

        self.action = action
        self.workspaceURL = workspaceURL
        self.privateRootURL = privateRootURL
        self.launchID = launchID
        self.ssid = ssid
        self.wifiDevice = values["--wifi-device"] ?? ""
        self.passwordFileURL = passwordFileURL
        self.fault = fault
        self.checkpoint = checkpoint
        self.checkpointMarkerURL = values["--checkpoint-marker"].map {
            URL(fileURLWithPath: $0, isDirectory: false)
        } ?? checkpoint.map { _ in
            workspaceURL.appendingPathComponent("checkpoint-marker.json")
        }
        self.checkpointGateURL = values["--checkpoint-gate"].map {
            URL(fileURLWithPath: $0, isDirectory: false)
        }
        self.readbackURL = values["--readback"].map {
            URL(fileURLWithPath: $0, isDirectory: false)
        } ?? workspaceURL.appendingPathComponent("readback-\(launchID).json")
    }
}

private enum WorkerError: LocalizedError {
    case invalidArguments
    case unsupportedCheckpoint(String)
    case unsupportedFault(String)
    case checkpointRequiresSave
    case faultRequiresSave
    case saveArgumentsMissing
    case defaultsUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            Self.usage
        case .unsupportedCheckpoint(let checkpoint):
            "Unsupported hotspot proof checkpoint: \(checkpoint)."
        case .unsupportedFault(let fault):
            "Unsupported hotspot proof fault: \(fault)."
        case .checkpointRequiresSave:
            "A blocking checkpoint can only be selected for the save action."
        case .faultRequiresSave:
            "An injected outer-edge fault can only be selected for the save action."
        case .saveArgumentsMissing:
            "The seed, save, and legacy-migration actions require --ssid and --password-file."
        case .defaultsUnavailable:
            "Could not create isolated proof preferences."
        }
    }

    private static let usage = """
    Usage: hotspot-configuration-proof-worker --action seed|save|recover|inspect|legacy-migration \
      --workspace PATH --private-root PATH --launch-id ID \
      [--ssid SSID --wifi-device DEVICE --password-file PRIVATE_PATH] \
      [--fault credential_stage_failure|credential_verification_mismatch|credential_verification_read_failure|active_pointer_precommit_failure|active_pointer_ambiguous_failure|cleanup_deletion_failure] \
      [--checkpoint before_staging|after_verified_staging|after_pointer_commit|during_cleanup] \
      [--checkpoint-marker PATH --checkpoint-gate PATH --readback PATH]
    """
}

private struct WorkerRuntime {
    let arguments: WorkerArguments
    let configurationStore: FileHotspotConfigurationStore
    let transactionStore: FaultInjectingHotspotConfigurationStore
    let trace: DurableRedactedHotspotProofTrace
    let credentialStore: DurableRecordingHotspotCredentialStore
    let defaults: UserDefaults
    let defaultsSuite: String
    let observer: DurableBlockingHotspotCheckpointObserver

    init(arguments: WorkerArguments) throws {
        self.arguments = arguments
        try FileManager.default.createDirectory(
            at: arguments.workspaceURL,
            withIntermediateDirectories: true
        )
        configurationStore = FileHotspotConfigurationStore(
            rootURL: arguments.workspaceURL.appendingPathComponent(
                "configuration",
                isDirectory: true
            )
        )
        trace = try DurableRedactedHotspotProofTrace(
            fileURL: arguments.workspaceURL.appendingPathComponent(
                "redacted-credential-trace.json"
            ),
            launchID: arguments.launchID
        )
        credentialStore = try DurableRecordingHotspotCredentialStore(
            privateRootURL: arguments.privateRootURL,
            trace: trace,
            fault: arguments.fault
        )
        transactionStore = FaultInjectingHotspotConfigurationStore(
            base: configurationStore,
            fault: arguments.fault,
            trace: trace
        )
        defaultsSuite = "HotspotConfigurationProofWorker.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            throw WorkerError.defaultsUnavailable
        }
        defaults.removePersistentDomain(forName: defaultsSuite)
        self.defaults = defaults
        observer = try DurableBlockingHotspotCheckpointObserver(
            selectedCheckpoint: arguments.checkpoint?.checkpoint,
            selectedBoundary: arguments.checkpoint?.boundary,
            markerURL: arguments.checkpointMarkerURL,
            gateURL: arguments.checkpointGateURL,
            launchID: arguments.launchID,
            trace: trace
        )
    }

    func run() throws {
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        try trace.record("\(arguments.action.rawValue)_process_started")

        switch arguments.action {
        case .seed, .save:
            let store = makeProductionStore()
            do {
                try rejectInitializationError(store)
                try store.save(try requestedSettings())
                try trace.record("save_returned")
                try writeReadback(store: store, errorCategory: nil)
            } catch {
                let category = errorCategory(for: error)
                try trace.record("save_error_\(category)")
                try writeReadback(store: store, errorCategory: category)
                if arguments.fault == nil { throw error }
            }
        case .recover:
            try trace.record("recovery_started")
            let store = makeProductionStore()
            try rejectInitializationError(store)
            if let active = try store.activeHotspotConfiguration() {
                _ = try store.loadHotspotPassword()
                try trace.record(
                    "active_credential_validated",
                    credentialReference: active.credentialReference
                )
            }
            try trace.record("recovery_returned")
            try writeReadback(store: store, errorCategory: nil)
        case .inspect:
            try trace.record("inspection_started")
            try writeReadback(store: nil, errorCategory: nil)
        case .legacyMigration:
            try seedLegacyConfiguration()
            let store = makeProductionStore()
            try rejectInitializationError(store)
            if let active = try store.activeHotspotConfiguration() {
                _ = try store.loadHotspotPassword()
                try trace.record(
                    "legacy_active_credential_validated",
                    credentialReference: active.credentialReference
                )
            }
            try trace.record("legacy_migration_returned")
            try writeReadback(store: store, errorCategory: nil)
        }
    }

    private func makeProductionStore() -> FileTravelSettingsStore {
        FileTravelSettingsStore(
            defaults: defaults,
            keychain: credentialStore,
            configurationStore: transactionStore,
            checkpointObserver: observer
        )
    }

    private func rejectInitializationError(_ store: FileTravelSettingsStore) throws {
        if let error = store.lastRecoveryError { throw error }
    }

    private func requestedSettings() throws -> TravelModeSettings {
        guard let ssid = arguments.ssid,
              let passwordFileURL = arguments.passwordFileURL else {
            throw WorkerError.saveArgumentsMissing
        }
        let password = try DurableHotspotProofFile.readExactPassword(
            from: passwordFileURL,
            privateRootURL: arguments.privateRootURL
        )
        return TravelModeSettings(
            hotspotSSID: ssid,
            hotspotPassword: password,
            wifiDevice: arguments.wifiDevice
        )
    }

    private func seedLegacyConfiguration() throws {
        guard let ssid = arguments.ssid,
              let passwordFileURL = arguments.passwordFileURL else {
            throw WorkerError.saveArgumentsMissing
        }
        let password = try DurableHotspotProofFile.readExactPassword(
            from: passwordFileURL,
            privateRootURL: arguments.privateRootURL
        )
        defaults.set(ssid, forKey: "fallbackHotspotSSID")
        defaults.set(arguments.wifiDevice, forKey: "wifiDevice")
        defaults.set(true, forKey: "fallbackHotspotPasswordSaved")
        try credentialStore.savePassword(
            password,
            account: "fallbackHotspotPassword"
        )
        try trace.record(
            "legacy_configuration_seeded",
            credentialReference: "fallbackHotspotPassword"
        )
    }

    private func errorCategory(for error: Error) -> String {
        if arguments.fault == .credentialVerificationReadFailure,
           error is KeychainError {
            return "credential_verification_read_failed"
        }
        if let error = error as? HotspotConfigurationError {
            switch error {
            case .unsupportedSchema:
                return "unsupported_schema"
            case .invalidRevisionID:
                return "invalid_revision_id"
            case .invalidSSIDByteCount:
                return "invalid_ssid_byte_count"
            case .invalidWiFiDevice:
                return "invalid_wifi_device"
            case .invalidCredentialReference:
                return "invalid_credential_reference"
            case .passwordRequired:
                return "password_required"
            case .noActiveConfiguration:
                return "no_active_configuration"
            case .credentialMissing:
                return "credential_missing"
            case .credentialStageFailed:
                return "credential_stage_failed"
            case .credentialReadbackMismatch:
                return "credential_readback_mismatch"
            case .persistenceFailed:
                return "persistence_failed"
            case .cleanupPending:
                return "cleanup_pending"
            case .cleanupFailed:
                return "cleanup_failed"
            case .legacyMigrationFailed:
                return "legacy_migration_failed"
            }
        }
        if error is KeychainError { return "keychain_error" }
        if error is HotspotConfigurationFileError { return "persistence_error" }
        return "unclassified_error"
    }

    private func writeReadback(
        store: FileTravelSettingsStore?,
        errorCategory: String?
    ) throws {
        let active = try configurationStore.loadActive()
        let settings = store?.load() ?? active.map {
            TravelModeSettings(
                hotspotSSID: $0.ssid,
                hotspotPassword: "",
                wifiDevice: $0.wifiDevice ?? ""
            )
        } ?? TravelModeSettings()
        let readback = HotspotConfigurationWorkerReadback(
            launchID: arguments.launchID,
            pid: getpid(),
            action: arguments.action.rawValue,
            injectedFault: arguments.fault,
            errorCategory: errorCategory,
            loadedSettings: HotspotProofLoadedSettings(
                hotspotSSID: settings.hotspotSSID,
                wifiDevice: settings.wifiDevice.isEmpty ? nil : settings.wifiDevice
            ),
            activeRevision: active,
            saveJournal: try configurationStore.loadSaveJournal(),
            credentialInventory: try credentialStore.inventory(),
            operations: try trace.read().operations
        )
        try DurableHotspotProofFile.writeJSON(readback, to: arguments.readbackURL)
        FileHandle.standardOutput.write(
            Data("readback=\(arguments.readbackURL.path)\n".utf8)
        )
    }
}

do {
    let arguments = try WorkerArguments(arguments: CommandLine.arguments)
    try WorkerRuntime(arguments: arguments).run()
} catch {
    let message = "hotspot-configuration-proof-worker: \(error.localizedDescription)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(64)
}
