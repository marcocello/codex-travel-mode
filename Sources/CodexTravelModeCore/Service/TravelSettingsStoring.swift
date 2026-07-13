import Foundation

public protocol TravelSettingsStoring: Sendable {
    func load() -> TravelModeSettings
    func hasSavedHotspotPassword() -> Bool
    func loadHotspotPassword() throws -> String
    func save(_ settings: TravelModeSettings) throws
    func loadRestoreSnapshot() -> TravelRestoreSnapshot?
    func saveRestoreSnapshot(_ snapshot: TravelRestoreSnapshot)
    func clearRestoreSnapshot()
}

public struct TravelRestoreSnapshot: Codable, Equatable, Sendable {
    public var lidClosedSleepOverrideEnabled: Bool?
    public var powerSettings: PowerSettingsSnapshot?
    public var wifiDevice: String?
    public var wifiPowerEnabled: Bool?

    public init(
        lidClosedSleepOverrideEnabled: Bool?,
        powerSettings: PowerSettingsSnapshot? = nil,
        wifiDevice: String?,
        wifiPowerEnabled: Bool?
    ) {
        self.lidClosedSleepOverrideEnabled = lidClosedSleepOverrideEnabled
        self.powerSettings = powerSettings
        self.wifiDevice = wifiDevice
        self.wifiPowerEnabled = wifiPowerEnabled
    }
}

public struct PowerSettingsSnapshot: Codable, Equatable, Sendable {
    public var battery: PowerProfileSettings?
    public var ac: PowerProfileSettings?

    public init(battery: PowerProfileSettings?, ac: PowerProfileSettings?) {
        self.battery = battery
        self.ac = ac
    }
}

public struct PowerProfileSettings: Codable, Equatable, Sendable {
    public var sleep: Int?
    public var ttysKeepAwake: Int?

    public init(sleep: Int?, ttysKeepAwake: Int?) {
        self.sleep = sleep
        self.ttysKeepAwake = ttysKeepAwake
    }
}
