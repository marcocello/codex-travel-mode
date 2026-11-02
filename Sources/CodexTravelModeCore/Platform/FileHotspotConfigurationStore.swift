import Foundation

public protocol HotspotConfigurationPersisting: Sendable {
    func loadActive() throws -> HotspotConfigurationRevision?
    func writeActive(_ revision: HotspotConfigurationRevision) throws
    func loadSaveJournal() throws -> HotspotConfigurationSaveJournal?
    func writeSaveJournal(_ journal: HotspotConfigurationSaveJournal) throws
    func clearSaveJournal() throws
}

public final class FileHotspotConfigurationStore:
    HotspotConfigurationPersisting,
    @unchecked Sendable {
    public static var defaultRootURL: URL {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("CodexTravelMode", isDirectory: true)
            .appendingPathComponent("HotspotConfiguration", isDirectory: true)
    }

    public let rootURL: URL
    public var activeFileURL: URL { rootURL.appendingPathComponent("active.json") }
    public var saveJournalFileURL: URL { rootURL.appendingPathComponent("save-journal.json") }

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    public init(
        rootURL: URL = FileHotspotConfigurationStore.defaultRootURL,
        fileManager: FileManager = FileManager()
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func loadActive() throws -> HotspotConfigurationRevision? {
        try locked { try read(HotspotConfigurationRevision.self, at: activeFileURL) }
    }

    public func writeActive(_ revision: HotspotConfigurationRevision) throws {
        try locked { try writeAndVerify(revision, at: activeFileURL) }
    }

    public func loadSaveJournal() throws -> HotspotConfigurationSaveJournal? {
        try locked { try read(HotspotConfigurationSaveJournal.self, at: saveJournalFileURL) }
    }

    public func writeSaveJournal(_ journal: HotspotConfigurationSaveJournal) throws {
        try locked { try writeAndVerify(journal, at: saveJournalFileURL) }
    }

    public func clearSaveJournal() throws {
        try locked {
            guard fileManager.fileExists(atPath: saveJournalFileURL.path) else { return }
            do {
                try fileManager.removeItem(at: saveJournalFileURL)
            } catch {
                throw HotspotConfigurationFileError.removeFailed(
                    path: saveJournalFileURL.path,
                    detail: error.localizedDescription
                )
            }
            guard !fileManager.fileExists(atPath: saveJournalFileURL.path) else {
                throw HotspotConfigurationFileError.readbackMismatch(saveJournalFileURL.path)
            }
        }
    }

    private func read<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(type, from: Data(contentsOf: url))
        } catch {
            throw HotspotConfigurationFileError.readFailed(
                path: url.path,
                detail: error.localizedDescription
            )
        }
    }

    private func writeAndVerify<Value: Codable & Equatable>(
        _ value: Value,
        at url: URL
    ) throws {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            throw HotspotConfigurationFileError.writeFailed(
                path: url.path,
                detail: error.localizedDescription
            )
        }
        guard let readback = try read(Value.self, at: url), readback == value else {
            throw HotspotConfigurationFileError.readbackMismatch(url.path)
        }
    }

    private func locked<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

public enum HotspotConfigurationFileError: LocalizedError, Equatable, Sendable {
    case readFailed(path: String, detail: String)
    case writeFailed(path: String, detail: String)
    case removeFailed(path: String, detail: String)
    case readbackMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .readFailed(let path, let detail):
            "Could not read hotspot configuration at \(path): \(detail)"
        case .writeFailed(let path, let detail):
            "Could not write hotspot configuration at \(path): \(detail)"
        case .removeFailed(let path, let detail):
            "Could not remove hotspot configuration at \(path): \(detail)"
        case .readbackMismatch(let path):
            "Hotspot configuration read-back did not match at \(path)."
        }
    }
}
