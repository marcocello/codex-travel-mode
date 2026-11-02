import Foundation

public protocol TravelSessionJournalStoring: Sendable {
    func load() async throws -> TravelSessionJournal?
    func create(_ journal: TravelSessionJournal) async throws -> TravelSessionJournal
    func update(
        _ journal: TravelSessionJournal,
        expectedRevision: Int
    ) async throws -> TravelSessionJournal
    func clear(sessionID: String, expectedRevision: Int) async throws
}

public enum TravelSessionJournalError: LocalizedError, Equatable {
    case alreadyExists
    case corrupt(String)
    case missing
    case staleSession
    case staleRevision(expected: Int, actual: Int)
    case readbackMismatch

    public var errorDescription: String? {
        switch self {
        case .alreadyExists:
            "A Travel Mode recovery journal already exists."
        case .corrupt(let detail):
            "The Travel Mode recovery journal is corrupt: \(detail)"
        case .missing:
            "The Travel Mode recovery journal is missing."
        case .staleSession:
            "A stale Travel Mode session tried to change a newer journal."
        case .staleRevision(let expected, let actual):
            "The Travel Mode journal changed concurrently (expected \(expected), found \(actual))."
        case .readbackMismatch:
            "The Travel Mode journal could not be verified after persistence."
        }
    }
}
