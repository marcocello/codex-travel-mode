import Foundation

public struct LivePlatformProductionUIValidator: Sendable {
    private let reader: any LivePlatformProductionUIReading

    public init(reader: any LivePlatformProductionUIReading) {
        self.reader = reader
    }

    public func validate(
        app: LivePlatformResolvedProcess,
        expectedTargetSSID: String,
        expectedWiFiDevice: String
    ) async throws -> LivePlatformProductionUIReadback {
        let readback = try await reader.readback(app: app)
        guard readback.appPID == app.pid,
              readback.appStartIdentity == app.startIdentity,
              readback.locationAuthorization == .authorized,
              readback.committedTargetSSID == expectedTargetSSID,
              readback.wifiDevice == expectedWiFiDevice,
              readback.targetVisible,
              readback.savedCredentialPresent,
              readback.codexRunning else {
            throw LivePlatformReadinessError.uiReadback(
                "production UI/configuration readback did not match"
            )
        }
        return readback
    }
}
