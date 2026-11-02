import Foundation

public struct WiFiStatus: Equatable, Sendable {
    public var device: String?
    public var networkName: String?
    public var rawOutput: String
    public var providerExitCode: Int32?
    public var commandFailed: Bool {
        if let providerExitCode { return providerExitCode != 0 }
        return rawOutput.localizedCaseInsensitiveContains("AuthorizationCreate() failed")
    }

    public var isConnected: Bool {
        networkName?.isEmpty == false
    }

    public init(
        device: String?,
        networkName: String?,
        rawOutput: String,
        providerExitCode: Int32? = nil
    ) {
        self.device = device
        self.networkName = networkName
        self.rawOutput = rawOutput
        self.providerExitCode = providerExitCode
    }
}
