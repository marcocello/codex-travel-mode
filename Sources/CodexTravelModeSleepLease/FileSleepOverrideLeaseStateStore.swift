import CryptoKit
import Darwin
import Foundation

public enum SleepOverrideLeaseFileStorePolicy: Sendable {
    case production
    case testSafe(rootDirectory: URL)
}

package struct SleepOverrideLeaseFileSecurityProfile: Equatable, Sendable {
    package var owner: uid_t
    package var group: gid_t
    package var directoryMode: mode_t
    package var fileMode: mode_t

    package func owns(userID: uid_t, groupID: gid_t) -> Bool {
        userID == owner && groupID == group
    }

    package func expectedMode(for kind: mode_t) -> mode_t? {
        switch kind {
        case S_IFDIR: directoryMode
        case S_IFREG: fileMode
        default: nil
        }
    }
}

public actor FileSleepOverrideLeaseStateStore: SleepOverrideLeaseStateStoring {
    public static let productionRootURL = URL(
        fileURLWithPath: "/Library/Application Support/com.codex.travelmode/SleepOverrideLease",
        isDirectory: true
    )
    package static let productionSecurityProfile = SleepOverrideLeaseFileSecurityProfile(
        owner: 0,
        group: 0,
        directoryMode: 0o750,
        fileMode: 0o600
    )

    private struct SecurityPolicy: Sendable {
        var rootURL: URL
        var managedDirectories: [URL]
        var profile: SleepOverrideLeaseFileSecurityProfile

        var directoryMode: mode_t { profile.directoryMode }
        var fileMode: mode_t { profile.fileMode }
    }

    private let security: SecurityPolicy
    private let journalURL: URL
    private let receiptsURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager = FileManager()

    public init(policy: SleepOverrideLeaseFileStorePolicy = .production) {
        let security = Self.makeSecurityPolicy(policy)
        self.security = security
        self.journalURL = security.rootURL.appendingPathComponent("active-lease.json")
        self.receiptsURL = security.rootURL.appendingPathComponent(
            "released-receipts",
            isDirectory: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    public func loadActiveJournal() async throws -> SleepOverrideLeaseJournal? {
        try ensureLayout()
        guard try itemExists(at: journalURL) else { return nil }
        return try decode(SleepOverrideLeaseJournal.self, at: journalURL)
    }

    public func createActiveJournal(
        _ journal: SleepOverrideLeaseJournal
    ) async throws -> SleepOverrideLeaseJournal {
        try ensureLayout()
        guard !(try itemExists(at: journalURL)) else {
            _ = try decode(SleepOverrideLeaseJournal.self, at: journalURL)
            throw SleepOverrideLeaseStateStoreError.activeJournalAlreadyExists
        }
        var persisted = journal
        persisted.schemaVersion = SleepOverrideLeaseJournal.currentSchemaVersion
        persisted.revision = 1
        return try persistAndReadBack(persisted, at: journalURL)
    }

    public func updateActiveJournal(
        _ journal: SleepOverrideLeaseJournal,
        expectedRevision: UInt64
    ) async throws -> SleepOverrideLeaseJournal {
        let current = try requireActiveJournal()
        guard current.binding == journal.binding else {
            throw SleepOverrideLeaseStateStoreError.bindingMismatch
        }
        guard current.revision == expectedRevision else {
            throw SleepOverrideLeaseStateStoreError.staleJournalRevision(
                expected: expectedRevision,
                actual: current.revision
            )
        }
        var persisted = journal
        persisted.schemaVersion = SleepOverrideLeaseJournal.currentSchemaVersion
        persisted.revision = current.revision + 1
        return try persistAndReadBack(persisted, at: journalURL)
    }

    public func removeActiveJournal(
        binding: SleepOverrideLeaseBinding,
        expectedRevision: UInt64
    ) async throws {
        let current = try requireActiveJournal()
        guard current.binding == binding else {
            throw SleepOverrideLeaseStateStoreError.bindingMismatch
        }
        guard current.revision == expectedRevision else {
            throw SleepOverrideLeaseStateStoreError.staleJournalRevision(
                expected: expectedRevision,
                actual: current.revision
            )
        }
        try removeSecureFile(at: journalURL)
    }

    public func loadReleasedReceipt(
        binding: SleepOverrideLeaseBinding
    ) async throws -> SleepOverrideLeaseStoredReceipt? {
        try ensureLayout()
        let url = try receiptURL(for: binding)
        guard try itemExists(at: url) else { return nil }
        let receipt = try decodeReleasedReceipt(at: url)
        guard receipt.binding == binding else {
            throw SleepOverrideLeaseStateStoreError.immutableReceiptConflict
        }
        return receipt
    }

    public func findReleasedReceipt(
        sessionID: String,
        requestID: String
    ) async throws -> SleepOverrideLeaseStoredReceipt? {
        try ensureLayout()
        let urls = try fileManager.contentsOfDirectory(
            at: receiptsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        var match: SleepOverrideLeaseStoredReceipt?
        for url in urls {
            let receipt = try decodeReleasedReceipt(at: url)
            guard url.standardizedFileURL == (try receiptURL(for: receipt.binding)).standardizedFileURL else {
                throw SleepOverrideLeaseStateStoreError.corruptState(
                    "\(url.lastPathComponent) does not match its receipt binding"
                )
            }
            guard receipt.binding.sessionID == sessionID,
                  receipt.binding.requestID == requestID else { continue }
            guard match == nil else {
                throw SleepOverrideLeaseStateStoreError.immutableReceiptConflict
            }
            match = receipt
        }
        return match
    }

    public func createReleasedReceipt(
        _ receipt: SleepOverrideLeaseStoredReceipt
    ) async throws -> SleepOverrideLeaseStoredReceipt {
        try ensureLayout()
        let url = try receiptURL(for: receipt.binding)
        if try itemExists(at: url) {
            let existing = try decodeReleasedReceipt(at: url)
            guard existing == receipt else {
                throw SleepOverrideLeaseStateStoreError.immutableReceiptConflict
            }
            return existing
        }
        var persisted = receipt
        persisted.schemaVersion = SleepOverrideLeaseStoredReceipt.currentSchemaVersion
        return try persistAndReadBack(persisted, at: url)
    }

    public func removeReleasedReceipt(
        binding: SleepOverrideLeaseBinding,
        expectedPrincipal: SleepOverrideLeaseCallerPrincipal
    ) async throws {
        let url = try receiptURL(for: binding)
        guard try itemExists(at: url) else { return }
        let receipt = try decodeReleasedReceipt(at: url)
        guard receipt.binding == binding, receipt.principal == expectedPrincipal else {
            throw SleepOverrideLeaseStateStoreError.bindingMismatch
        }
        try removeSecureFile(at: url)
    }
}

private extension FileSleepOverrideLeaseStateStore {
    private static func makeSecurityPolicy(
        _ policy: SleepOverrideLeaseFileStorePolicy
    ) -> SecurityPolicy {
        switch policy {
        case .production:
            let applicationRoot = productionRootURL.deletingLastPathComponent()
            return SecurityPolicy(
                rootURL: productionRootURL,
                managedDirectories: [applicationRoot, productionRootURL],
                profile: productionSecurityProfile
            )
        case .testSafe(let rootDirectory):
            return SecurityPolicy(
                rootURL: rootDirectory.standardizedFileURL,
                managedDirectories: [rootDirectory.standardizedFileURL],
                profile: SleepOverrideLeaseFileSecurityProfile(
                    owner: geteuid(),
                    group: getegid(),
                    directoryMode: 0o700,
                    fileMode: 0o600
                )
            )
        }
    }

    func ensureLayout() throws {
        for directory in security.managedDirectories {
            try ensureSecureDirectory(at: directory)
        }
        try ensureSecureDirectory(at: receiptsURL)
    }

    func ensureSecureDirectory(at url: URL) throws {
        if let info = try fileStatus(at: url) {
            try validate(info, at: url, kind: S_IFDIR, mode: security.directoryMode)
            return
        }
        guard Darwin.mkdir(url.path, security.directoryMode) == 0 else {
            throw posixError("create directory", at: url)
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError("open directory", at: url) }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, security.directoryMode) == 0 else {
            throw posixError("set directory mode", at: url)
        }
        guard let info = try fileStatus(at: url) else {
            throw SleepOverrideLeaseStateStoreError.readbackMismatch(url.path)
        }
        try validate(info, at: url, kind: S_IFDIR, mode: security.directoryMode)
    }

    func requireActiveJournal() throws -> SleepOverrideLeaseJournal {
        try ensureLayout()
        guard try itemExists(at: journalURL) else {
            throw SleepOverrideLeaseStateStoreError.activeJournalMissing
        }
        return try decode(SleepOverrideLeaseJournal.self, at: journalURL)
    }

    func decodeReleasedReceipt(at url: URL) throws -> SleepOverrideLeaseStoredReceipt {
        let receipt = try decode(SleepOverrideLeaseStoredReceipt.self, at: url)
        guard receipt.schemaVersion == SleepOverrideLeaseStoredReceipt.currentSchemaVersion else {
            throw SleepOverrideLeaseStateStoreError.corruptState(
                "unsupported released receipt schema version \(receipt.schemaVersion)"
            )
        }
        return receipt
    }

    func persistAndReadBack<Value: Codable>(
        _ value: Value,
        at url: URL
    ) throws -> Value {
        let data = try encoder.encode(value)
        try atomicSecureWrite(data, to: url)
        let readback = try decode(Value.self, at: url)
        let readbackData = try encoder.encode(readback)
        guard readbackData == data else {
            throw SleepOverrideLeaseStateStoreError.readbackMismatch(url.path)
        }
        return readback
    }

    func decode<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value {
        let data = try secureRead(at: url)
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw SleepOverrideLeaseStateStoreError.corruptState(
                "\(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    func receiptURL(for binding: SleepOverrideLeaseBinding) throws -> URL {
        let data = try encoder.encode(binding)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return receiptsURL.appendingPathComponent("\(digest).json", isDirectory: false)
    }
}

private extension FileSleepOverrideLeaseStateStore {
    func atomicSecureWrite(_ data: Data, to destination: URL) throws {
        try ensureLayout()
        if let info = try fileStatus(at: destination) {
            try validate(info, at: destination, kind: S_IFREG, mode: security.fileMode)
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            security.fileMode
        )
        guard descriptor >= 0 else { throw posixError("create temporary file", at: temporary) }
        do {
            guard Darwin.fchmod(descriptor, security.fileMode) == 0 else {
                throw posixError("set file mode", at: temporary)
            }
            try writeAll(data, to: descriptor, at: temporary)
            guard Darwin.fsync(descriptor) == 0 else { throw posixError("fsync", at: temporary) }
            guard Darwin.close(descriptor) == 0 else { throw posixError("close", at: temporary) }
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw posixError("replace", at: destination)
            }
            try syncDirectory(destination.deletingLastPathComponent())
        } catch {
            _ = Darwin.close(descriptor)
            _ = Darwin.unlink(temporary.path)
            throw error
        }
    }

    func secureRead(at url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError("open", at: url) }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw posixError("inspect", at: url) }
        try validate(info, at: url, kind: S_IFREG, mode: security.fileMode)
        guard info.st_size >= 0, info.st_size <= 1_048_576 else {
            throw SleepOverrideLeaseStateStoreError.corruptState("\(url.path) has an unsafe size")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else { throw posixError("read", at: url) }
            data.append(buffer, count: count)
        }
        return data
    }

    func writeAll(_ data: Data, to descriptor: Int32, at url: URL) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                guard count > 0 else { throw posixError("write", at: url) }
                offset += count
            }
        }
    }

    func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError("open directory", at: url) }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError("fsync directory", at: url) }
    }

    func removeSecureFile(at url: URL) throws {
        guard let info = try fileStatus(at: url) else { return }
        try validate(info, at: url, kind: S_IFREG, mode: security.fileMode)
        guard Darwin.unlink(url.path) == 0 else { throw posixError("remove", at: url) }
        try syncDirectory(url.deletingLastPathComponent())
        guard try fileStatus(at: url) == nil else {
            throw SleepOverrideLeaseStateStoreError.readbackMismatch(url.path)
        }
    }
}

private extension FileSleepOverrideLeaseStateStore {
    func itemExists(at url: URL) throws -> Bool {
        try fileStatus(at: url) != nil
    }

    func fileStatus(at url: URL) throws -> stat? {
        var info = stat()
        if Darwin.lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw posixError("inspect", at: url)
    }

    func validate(_ info: stat, at url: URL, kind: mode_t, mode: mode_t) throws {
        guard info.st_mode & S_IFMT == kind else {
            throw SleepOverrideLeaseStateStoreError.unsafePath("\(url.path) has the wrong type")
        }
        guard security.profile.owns(userID: info.st_uid, groupID: info.st_gid) else {
            throw SleepOverrideLeaseStateStoreError.unsafePath("\(url.path) has unsafe ownership")
        }
        guard security.profile.expectedMode(for: kind) == mode,
              info.st_mode & 0o777 == mode else {
            throw SleepOverrideLeaseStateStoreError.unsafePath("\(url.path) has unsafe mode")
        }
    }

    func posixError(_ operation: String, at url: URL) -> SleepOverrideLeaseStateStoreError {
        let detail = String(cString: strerror(errno))
        return .unsafePath("Could not \(operation) \(url.path): \(detail)")
    }
}
