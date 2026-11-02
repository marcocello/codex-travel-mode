import Foundation

public actor FileTravelSessionJournalStore: TravelSessionJournalStoring {
    public static var defaultFileURL: URL {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("CodexTravelMode", isDirectory: true)
            .appendingPathComponent("travel-session-journal.json", isDirectory: false)
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL = FileTravelSessionJournalStore.defaultFileURL) {
        self.fileURL = fileURL
        self.fileManager = FileManager()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func load() throws -> TravelSessionJournal? {
        try readJournalIfPresent()
    }

    public func create(_ journal: TravelSessionJournal) throws -> TravelSessionJournal {
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try readJournalIfPresent()
            throw TravelSessionJournalError.alreadyExists
        }

        var persisted = journal
        persisted.revision = 1
        try persistAndVerify(persisted)
        return persisted
    }

    public func update(
        _ journal: TravelSessionJournal,
        expectedRevision: Int
    ) throws -> TravelSessionJournal {
        let current = try requiredJournal()
        try validateOwnership(
            current: current,
            requestedSessionID: journal.sessionID,
            expectedRevision: expectedRevision
        )

        var persisted = journal
        persisted.revision = current.revision + 1
        try persistAndVerify(persisted)
        return persisted
    }

    public func clear(sessionID: String, expectedRevision: Int) throws {
        let current = try requiredJournal()
        try validateOwnership(
            current: current,
            requestedSessionID: sessionID,
            expectedRevision: expectedRevision
        )

        try fileManager.removeItem(at: fileURL)
        guard !fileManager.fileExists(atPath: fileURL.path) else {
            throw TravelSessionJournalError.readbackMismatch
        }
    }

    private func requiredJournal() throws -> TravelSessionJournal {
        guard let journal = try readJournalIfPresent() else {
            throw TravelSessionJournalError.missing
        }
        return journal
    }

    private func readJournalIfPresent() throws -> TravelSessionJournal? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        do {
            return try decoder.decode(TravelSessionJournal.self, from: data)
        } catch {
            throw TravelSessionJournalError.corrupt(error.localizedDescription)
        }
    }

    private func validateOwnership(
        current: TravelSessionJournal,
        requestedSessionID: String,
        expectedRevision: Int
    ) throws {
        guard current.sessionID == requestedSessionID else {
            throw TravelSessionJournalError.staleSession
        }
        guard current.revision == expectedRevision else {
            throw TravelSessionJournalError.staleRevision(
                expected: expectedRevision,
                actual: current.revision
            )
        }
    }

    private func persistAndVerify(_ journal: TravelSessionJournal) throws {
        try ensureParentDirectory()
        let data = try encoder.encode(journal)
        try data.write(to: fileURL, options: .atomic)

        guard let readback = try readJournalIfPresent(), readback == journal else {
            throw TravelSessionJournalError.readbackMismatch
        }
    }

    private func ensureParentDirectory() throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
