import Foundation

public protocol TravelSettingsStoring: Sendable {
    func load() -> TravelModeSettings
    func hasSavedHotspotPassword() -> Bool
    func loadHotspotPassword() throws -> String
    func loadHotspotPassword(credentialReference: String) throws -> String
    func save(_ settings: TravelModeSettings) throws
    func recoverHotspotConfiguration() throws
    func activeHotspotConfiguration() throws -> HotspotConfigurationRevision?
    func legacyHotspotDraft() -> TravelModeSettings?
}

public extension TravelSettingsStoring {
    func recoverHotspotConfiguration() throws {}

    func activeHotspotConfiguration() throws -> HotspotConfigurationRevision? {
        nil
    }

    func legacyHotspotDraft() -> TravelModeSettings? {
        nil
    }
}
