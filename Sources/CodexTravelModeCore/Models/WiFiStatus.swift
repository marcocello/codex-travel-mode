import Foundation

public struct WiFiStatus: Equatable, Sendable {
    public var device: String?
    public var networkName: String?
    public var rawOutput: String
    public var commandFailed: Bool {
        rawOutput.localizedCaseInsensitiveContains("AuthorizationCreate() failed")
    }

    public var isConnected: Bool {
        networkName?.isEmpty == false
    }

    public init(device: String?, networkName: String?, rawOutput: String) {
        self.device = device
        self.networkName = networkName
        self.rawOutput = rawOutput
    }
}
