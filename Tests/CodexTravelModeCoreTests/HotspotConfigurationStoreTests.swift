import CodexTravelModeCore
import Foundation
import XCTest

final class HotspotConfigurationStoreTests: XCTestCase {
    func testFileSaveKeepsExactPasswordAndWritesOnlyCommittedRevision() throws {
        let context = try makeContext()
        let exactPassword = "  proof password\n"
        let store = makeStore(context: context)

        XCTAssertEqual(TravelModeSettings().hotspotSSID, "")
        XCTAssertEqual(
            TravelModeSettings(hotspotPassword: exactPassword).trimmedHotspotPassword,
            exactPassword
        )

        try store.save(
            TravelModeSettings(
                hotspotSSID: " Example iPhone ",
                hotspotPassword: exactPassword,
                wifiDevice: "en0"
            )
        )

        let active = try XCTUnwrap(store.activeHotspotConfiguration())
        XCTAssertEqual(active.schemaVersion, 1)
        XCTAssertEqual(active.ssid, " Example iPhone ")
        XCTAssertEqual(active.wifiDevice, "en0")
        XCTAssertEqual(context.keychain.passwords[active.credentialReference], exactPassword)
        XCTAssertEqual(try store.loadHotspotPassword(), exactPassword)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.files.activeFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.files.saveJournalFileURL.path))
    }

    func testCanonicalPasswordNormalizationCannotPassExactReadbackVerification() throws {
        let context = try makeContext()
        context.keychain.savedPasswordTransform = { value in
            value.precomposedStringWithCanonicalMapping
        }
        let store = makeStore(context: context)

        XCTAssertThrowsError(
            try store.save(
                TravelModeSettings(
                    hotspotSSID: "Example iPhone",
                    hotspotPassword: "secre\u{0065}\u{0301}",
                    wifiDevice: "en0"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? HotspotConfigurationError,
                .credentialReadbackMismatch
            )
        }
        XCTAssertNil(try store.activeHotspotConfiguration())
        XCTAssertTrue(context.keychain.passwords.isEmpty)
        XCTAssertNil(try context.files.loadSaveJournal())
    }

    func testBlankPasswordReusesOnlyExactSameSSIDCredential() throws {
        let context = try makeContext()
        let observer = RecordingConfigurationCheckpointObserver()
        let store = makeStore(context: context, observer: observer)
        try store.save(
            TravelModeSettings(
                hotspotSSID: "Example iPhone",
                hotspotPassword: "first secret",
                wifiDevice: "en0"
            )
        )
        let first = try XCTUnwrap(store.activeHotspotConfiguration())
        observer.checkpoints.removeAll()

        try store.save(
            TravelModeSettings(
                hotspotSSID: "Example iPhone",
                hotspotPassword: "",
                wifiDevice: "en1"
            )
        )
        let deviceOnly = try XCTUnwrap(store.activeHotspotConfiguration())
        XCTAssertNotEqual(deviceOnly.revisionID, first.revisionID)
        XCTAssertEqual(deviceOnly.credentialReference, first.credentialReference)
        XCTAssertEqual(deviceOnly.wifiDevice, "en1")
        XCTAssertEqual(context.keychain.savedAccounts, [first.credentialReference])
        XCTAssertEqual(
            observer.checkpoints,
            [.prepared, .pointerCommitted, .journalCleared]
        )

        XCTAssertThrowsError(
            try store.save(
                TravelModeSettings(
                    hotspotSSID: "Another iPhone",
                    hotspotPassword: "",
                    wifiDevice: "en1"
                )
            )
        ) { error in
            XCTAssertEqual(error as? HotspotConfigurationError, .passwordRequired)
        }
        XCTAssertEqual(try store.activeHotspotConfiguration(), deviceOnly)

        let canonicalVariant = "Example iPhon\u{0065}\u{0301}"
        try store.save(
            TravelModeSettings(
                hotspotSSID: "Example iPhon\u{00E9}",
                hotspotPassword: "canonical secret",
                wifiDevice: "en1"
            )
        )
        let composed = try XCTUnwrap(store.activeHotspotConfiguration())
        XCTAssertThrowsError(
            try store.save(
                TravelModeSettings(
                    hotspotSSID: canonicalVariant,
                    hotspotPassword: "",
                    wifiDevice: "en1"
                )
            )
        ) { error in
            XCTAssertEqual(error as? HotspotConfigurationError, .passwordRequired)
        }
        XCTAssertEqual(try store.activeHotspotConfiguration(), composed)
    }

    func testAmbiguousPointerCommitUsesActiveReadback() throws {
        let context = try makeContext()
        let persistence = ThrowAfterActiveWriteStore(base: context.files)
        let store = FileTravelSettingsStore(
            defaults: context.defaults,
            keychain: context.keychain,
            configurationStore: persistence
        )

        try store.save(
            TravelModeSettings(
                hotspotSSID: "Example iPhone",
                hotspotPassword: "secret",
                wifiDevice: "en0"
            )
        )

        let active = try XCTUnwrap(store.activeHotspotConfiguration())
        XCTAssertEqual(active.ssid, "Example iPhone")
        XCTAssertTrue(try context.keychain.passwordExists(account: active.credentialReference))
        XCTAssertNil(try context.files.loadSaveJournal())
    }

    func testCleanupFailureKeepsActiveValidAndBlocksSaveUntilRecovery() throws {
        let context = try makeContext()
        let observer = RecordingConfigurationCheckpointObserver()
        let store = makeStore(context: context, observer: observer)
        try store.save(
            TravelModeSettings(
                hotspotSSID: "Old iPhone",
                hotspotPassword: "old secret",
                wifiDevice: "en0"
            )
        )
        let old = try XCTUnwrap(store.activeHotspotConfiguration())
        context.keychain.failDeleteAccounts.insert(old.credentialReference)

        XCTAssertThrowsError(
            try store.save(
                TravelModeSettings(
                    hotspotSSID: "New iPhone",
                    hotspotPassword: "new secret",
                    wifiDevice: "en0"
                )
            )
        ) { error in
            guard case .cleanupFailed = error as? HotspotConfigurationError else {
                return XCTFail("Expected cleanupFailed, got \(error)")
            }
        }

        let active = try XCTUnwrap(store.activeHotspotConfiguration())
        XCTAssertEqual(active.ssid, "New iPhone")
        XCTAssertTrue(store.hasSavedHotspotPassword())
        XCTAssertEqual(try store.loadHotspotPassword(), "new secret")
        XCTAssertEqual(try context.files.loadSaveJournal()?.phase, .cleanupPending)

        XCTAssertThrowsError(
            try store.save(
                TravelModeSettings(
                    hotspotSSID: "Third iPhone",
                    hotspotPassword: "third secret",
                    wifiDevice: "en0"
                )
            )
        ) { error in
            guard case .cleanupFailed = error as? HotspotConfigurationError else {
                return XCTFail("Expected cleanupFailed, got \(error)")
            }
        }
        XCTAssertEqual(try store.activeHotspotConfiguration(), active)
        XCTAssertFalse(context.keychain.savedAccounts.contains { account in
            account != old.credentialReference && account != active.credentialReference
        })

        context.keychain.failDeleteAccounts.remove(old.credentialReference)
        try store.save(
            TravelModeSettings(
                hotspotSSID: "Third iPhone",
                hotspotPassword: "third secret",
                wifiDevice: "en0"
            )
        )
        let third = try XCTUnwrap(store.activeHotspotConfiguration())
        XCTAssertNil(try context.files.loadSaveJournal())
        XCTAssertNil(context.keychain.passwords[old.credentialReference])
        XCTAssertNil(context.keychain.passwords[active.credentialReference])
        XCTAssertEqual(third.ssid, "Third iPhone")
        XCTAssertEqual(try store.loadHotspotPassword(), "third secret")
    }

    func testIndeterminatePointerReadbackLeavesJournalForNextProcessRecovery() throws {
        let context = try makeContext()
        let persistence = ThrowAfterActiveWriteAndReadStore(base: context.files)
        let interrupted = FileTravelSettingsStore(
            defaults: context.defaults,
            keychain: context.keychain,
            configurationStore: persistence
        )

        XCTAssertThrowsError(
            try interrupted.save(
                TravelModeSettings(
                    hotspotSSID: "Candidate iPhone",
                    hotspotPassword: "candidate secret",
                    wifiDevice: "en0"
                )
            )
        ) { error in
            guard case .persistenceFailed = error as? HotspotConfigurationError else {
                return XCTFail("Expected an indeterminate persistence failure, got \(error)")
            }
        }
        XCTAssertEqual(try context.files.loadSaveJournal()?.phase, .credentialStaged)

        let recovered = makeStore(context: context)
        let active = try XCTUnwrap(recovered.activeHotspotConfiguration())
        XCTAssertEqual(active.ssid, "Candidate iPhone")
        XCTAssertEqual(try recovered.loadHotspotPassword(), "candidate secret")
        XCTAssertNil(try context.files.loadSaveJournal())
        XCTAssertEqual(Set(context.keychain.passwords.keys), [active.credentialReference])
    }

    func testRecoveryConvergesCredentialStagedJournalOnEitherSideOfPointerCommit() throws {
        let context = try makeContext()
        let previous = try revision(
            ssid: "Old iPhone",
            credentialReference: "credential.old"
        )
        let candidate = try revision(
            ssid: "New iPhone",
            credentialReference: "credential.new"
        )
        context.keychain.passwords[previous.credentialReference] = "old"
        context.keychain.passwords[candidate.credentialReference] = "new"
        try context.files.writeActive(previous)
        try context.files.writeSaveJournal(
            HotspotConfigurationSaveJournal(
                phase: .credentialStaged,
                candidate: candidate,
                previousRevision: previous
            )
        )

        _ = makeStore(context: context)
        XCTAssertEqual(try context.files.loadActive(), previous)
        XCTAssertNil(context.keychain.passwords[candidate.credentialReference])
        XCTAssertNil(try context.files.loadSaveJournal())

        context.keychain.passwords[candidate.credentialReference] = "new"
        try context.files.writeActive(candidate)
        try context.files.writeSaveJournal(
            HotspotConfigurationSaveJournal(
                phase: .credentialStaged,
                candidate: candidate,
                previousRevision: previous
            )
        )
        _ = makeStore(context: context)
        XCTAssertEqual(try context.files.loadActive(), candidate)
        XCTAssertNil(context.keychain.passwords[previous.credentialReference])
        XCTAssertNil(try context.files.loadSaveJournal())
    }

    func testCompleteLegacyPairMigratesAndIncompleteLegacyStateIsPreserved() throws {
        let complete = try makeContext()
        complete.defaults.set("Legacy iPhone", forKey: "fallbackHotspotSSID")
        complete.defaults.set("invalid device name", forKey: "wifiDevice")
        complete.defaults.set(true, forKey: "fallbackHotspotPasswordSaved")
        complete.keychain.passwords["fallbackHotspotPassword"] = " legacy secret "

        let migrated = makeStore(context: complete)
        let active = try XCTUnwrap(migrated.activeHotspotConfiguration())
        XCTAssertEqual(active.ssid, "Legacy iPhone")
        XCTAssertNil(active.wifiDevice)
        XCTAssertEqual(try migrated.loadHotspotPassword(), " legacy secret ")
        XCTAssertNil(complete.keychain.passwords["fallbackHotspotPassword"])
        XCTAssertNil(complete.defaults.string(forKey: "fallbackHotspotSSID"))

        let incomplete = try makeContext()
        incomplete.defaults.set("SSID without credential", forKey: "fallbackHotspotSSID")
        let incompleteStore = makeStore(context: incomplete)
        XCTAssertNil(try incompleteStore.activeHotspotConfiguration())
        XCTAssertEqual(incompleteStore.load().hotspotSSID, "")
        XCTAssertEqual(
            incompleteStore.legacyHotspotDraft()?.hotspotSSID,
            "SSID without credential"
        )

        let credentialOnly = try makeContext()
        credentialOnly.keychain.passwords["fallbackHotspotPassword"] = "orphan preserved"
        let credentialOnlyStore = makeStore(context: credentialOnly)
        XCTAssertNil(try credentialOnlyStore.activeHotspotConfiguration())
        XCTAssertEqual(
            credentialOnly.keychain.passwords["fallbackHotspotPassword"],
            "orphan preserved"
        )
    }

    func testPasswordLoadMapsOnlyNotFoundAndPreservesOtherKeychainErrors() throws {
        let missing = try makeContext()
        let active = try revision(
            ssid: "Example iPhone",
            credentialReference: "credential.missing"
        )
        try missing.files.writeActive(active)
        let missingStore = makeStore(context: missing)
        XCTAssertThrowsError(try missingStore.loadHotspotPassword()) { error in
            XCTAssertEqual(
                error as? HotspotConfigurationError,
                .credentialMissing("credential.missing")
            )
        }

        let denied = try makeContext()
        try denied.files.writeActive(active)
        denied.keychain.readErrors[active.credentialReference] = .readFailed(-25293)
        let deniedStore = makeStore(context: denied)
        XCTAssertThrowsError(try deniedStore.loadHotspotPassword()) { error in
            XCTAssertEqual(error as? KeychainError, .readFailed(-25293))
        }
    }

    func testLegacyMigrationPreservesLockedDeniedAndCorruptCredentialFailures() throws {
        let failures: [KeychainError] = [
            .inaccessible(-25308),
            .denied(-25293),
            .corruptData(-26275),
            .invalidPasswordData
        ]

        for failure in failures {
            let context = try makeContext()
            context.defaults.set("Legacy iPhone", forKey: "fallbackHotspotSSID")
            context.defaults.set("en0", forKey: "wifiDevice")
            context.keychain.readErrors["fallbackHotspotPassword"] = failure

            let store = makeStore(context: context)

            XCTAssertEqual(store.lastRecoveryError as? KeychainError, failure)
            XCTAssertThrowsError(try store.recoverHotspotConfiguration()) { error in
                XCTAssertEqual(error as? KeychainError, failure)
            }
            XCTAssertThrowsError(try store.loadHotspotPassword()) { error in
                XCTAssertEqual(error as? KeychainError, failure)
            }
            XCTAssertNil(try store.activeHotspotConfiguration())
            XCTAssertEqual(
                context.defaults.string(forKey: "fallbackHotspotSSID"),
                "Legacy iPhone"
            )
        }
    }
}

private extension HotspotConfigurationStoreTests {
    struct Context {
        var root: URL
        var defaults: UserDefaults
        var keychain: MemoryKeychainPasswordStore
        var files: FileHotspotConfigurationStore
    }

    func makeContext() throws -> Context {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotspot-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "HotspotConfigurationStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return Context(
            root: root,
            defaults: defaults,
            keychain: MemoryKeychainPasswordStore(),
            files: FileHotspotConfigurationStore(rootURL: root)
        )
    }

    func makeStore(
        context: Context,
        observer: any HotspotConfigurationCheckpointObserving =
            NoOpHotspotConfigurationCheckpointObserver()
    ) -> FileTravelSettingsStore {
        FileTravelSettingsStore(
            defaults: context.defaults,
            keychain: context.keychain,
            configurationStore: context.files,
            checkpointObserver: observer
        )
    }

    func revision(
        ssid: String,
        credentialReference: String
    ) throws -> HotspotConfigurationRevision {
        try HotspotConfigurationRevision(
            ssid: ssid,
            wifiDevice: "en0",
            credentialReference: credentialReference
        )
    }
}

private final class MemoryKeychainPasswordStore:
    KeychainPasswordStoring,
    @unchecked Sendable {
    var passwords: [String: String] = [:]
    var savedAccounts: [String] = []
    var deletedAccounts: [String] = []
    var failDeleteAccounts: Set<String> = []
    var readErrors: [String: KeychainError] = [:]
    var savedPasswordTransform: ((String) -> String)?

    func readPassword(account: String) throws -> String {
        if let error = readErrors[account] { throw error }
        guard let password = passwords[account] else { throw KeychainError.notFound }
        return password
    }

    func savePassword(_ password: String, account: String) throws {
        if let existing = passwords[account],
           !existing.hasExactUTF8Representation(as: password) {
            throw KeychainError.credentialConflict
        }
        passwords[account] = savedPasswordTransform?(password) ?? password
        savedAccounts.append(account)
    }

    func passwordExists(account: String) throws -> Bool {
        if let error = readErrors[account] { throw error }
        return passwords[account] != nil
    }

    func deletePassword(account: String) throws {
        if failDeleteAccounts.contains(account) {
            throw KeychainError.deleteFailed(-1)
        }
        passwords.removeValue(forKey: account)
        deletedAccounts.append(account)
    }
}

private final class ThrowAfterActiveWriteAndReadStore:
    HotspotConfigurationPersisting,
    @unchecked Sendable {
    private let base: FileHotspotConfigurationStore
    private var failNextActiveRead = false

    init(base: FileHotspotConfigurationStore) {
        self.base = base
    }

    func loadActive() throws -> HotspotConfigurationRevision? {
        if failNextActiveRead {
            failNextActiveRead = false
            throw HotspotConfigurationFileError.readFailed(
                path: base.activeFileURL.path,
                detail: "injected unavailable read-back"
            )
        }
        return try base.loadActive()
    }

    func writeActive(_ revision: HotspotConfigurationRevision) throws {
        try base.writeActive(revision)
        failNextActiveRead = true
        throw HotspotConfigurationFileError.writeFailed(
            path: base.activeFileURL.path,
            detail: "injected ambiguous write"
        )
    }

    func loadSaveJournal() throws -> HotspotConfigurationSaveJournal? {
        try base.loadSaveJournal()
    }

    func writeSaveJournal(_ journal: HotspotConfigurationSaveJournal) throws {
        try base.writeSaveJournal(journal)
    }

    func clearSaveJournal() throws {
        try base.clearSaveJournal()
    }
}

private final class ThrowAfterActiveWriteStore:
    HotspotConfigurationPersisting,
    @unchecked Sendable {
    private let base: FileHotspotConfigurationStore
    private var shouldThrow = true

    init(base: FileHotspotConfigurationStore) {
        self.base = base
    }

    func loadActive() throws -> HotspotConfigurationRevision? {
        try base.loadActive()
    }

    func writeActive(_ revision: HotspotConfigurationRevision) throws {
        try base.writeActive(revision)
        if shouldThrow {
            shouldThrow = false
            throw HotspotConfigurationFileError.writeFailed(
                path: base.activeFileURL.path,
                detail: "injected post-write failure"
            )
        }
    }

    func loadSaveJournal() throws -> HotspotConfigurationSaveJournal? {
        try base.loadSaveJournal()
    }

    func writeSaveJournal(_ journal: HotspotConfigurationSaveJournal) throws {
        try base.writeSaveJournal(journal)
    }

    func clearSaveJournal() throws {
        try base.clearSaveJournal()
    }
}

private final class RecordingConfigurationCheckpointObserver:
    HotspotConfigurationCheckpointObserving,
    @unchecked Sendable {
    var checkpoints: [HotspotConfigurationCheckpoint] = []

    func reached(
        _ checkpoint: HotspotConfigurationCheckpoint,
        journal: HotspotConfigurationSaveJournal?
    ) {
        checkpoints.append(checkpoint)
    }
}
