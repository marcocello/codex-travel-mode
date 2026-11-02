import Darwin
import Foundation

public enum LiveObservedSystemError: Error, Equatable, Sendable {
    case malformedOutput(String)
    case unauthorized(String)
    case indeterminate(String)
    case identityMismatch(String)
}

public enum LiveObservedPowerSource: String, Codable, Sendable {
    case battery = "battery_power"
    case ac = "ac_power"
}

public struct LiveObservedBattery: Codable, Equatable, Sendable {
    public let source: LiveObservedPowerSource
    public let percent: Int

    public init(source: LiveObservedPowerSource, percent: Int) throws {
        guard (0...100).contains(percent) else {
            throw LiveObservedSystemError.malformedOutput("battery percent is out of range")
        }
        self.source = source
        self.percent = percent
    }
}

public enum LiveObservedAddressFamily: String, Codable, Sendable {
    case ipv4
    case ipv6
}

public enum LiveObservedAddressClassification: String, Codable, Sendable {
    case usable
    case privateNetwork = "private_network"
    case documentation
    case reserved
    case loopback
    case linkLocal = "link_local"
    case unspecified
    case multicast
}

public struct LiveObservedIPAddress: Equatable, Sendable {
    public let family: LiveObservedAddressFamily
    public let rawBytes: Data
    public let canonicalText: String
    public let classification: LiveObservedAddressClassification

    public init(_ text: String) throws {
        let unscoped = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        if let bytes = Self.parse(unscoped, family: AF_INET, count: 4) {
            family = .ipv4
            rawBytes = bytes
            canonicalText = try Self.render(bytes, family: AF_INET)
            classification = Self.classifyIPv4(bytes)
            return
        }
        if let bytes = Self.parse(unscoped, family: AF_INET6, count: 16) {
            family = .ipv6
            rawBytes = bytes
            canonicalText = try Self.render(bytes, family: AF_INET6)
            classification = Self.classifyIPv6(bytes)
            return
        }
        throw LiveObservedSystemError.malformedOutput("invalid IP address")
    }

    public init(family: LiveObservedAddressFamily, rawBytes: Data) throws {
        let expectedCount = family == .ipv4 ? 4 : 16
        guard rawBytes.count == expectedCount else {
            throw LiveObservedSystemError.malformedOutput("IP byte count does not match family")
        }
        self.family = family
        self.rawBytes = rawBytes
        let systemFamily = family == .ipv4 ? AF_INET : AF_INET6
        canonicalText = try Self.render(rawBytes, family: systemFamily)
        classification = family == .ipv4
            ? Self.classifyIPv4(rawBytes)
            : Self.classifyIPv6(rawBytes)
    }

    public var isUsable: Bool {
        classification == .usable || classification == .privateNetwork
    }
    public var isPubliclyRoutable: Bool { classification == .usable }

    private static func parse(_ text: String, family: Int32, count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        guard inet_pton(family, text, &bytes) == 1 else { return nil }
        return Data(bytes)
    }

    private static func render(_ data: Data, family: Int32) throws -> String {
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let rendered = data.withUnsafeBytes {
            inet_ntop(family, $0.baseAddress, &output, socklen_t(output.count))
        }
        guard rendered != nil else {
            throw LiveObservedSystemError.malformedOutput("could not canonicalize IP address")
        }
        let end = output.firstIndex(of: 0) ?? output.endIndex
        return String(
            decoding: output[..<end].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    private static func classifyIPv4(_ data: Data) -> LiveObservedAddressClassification {
        let bytes = [UInt8](data)
        if bytes == [0, 0, 0, 0] { return .unspecified }
        if bytes[0] == 0 { return .reserved }
        if bytes[0] == 10
            || (bytes[0] == 100 && (64...127).contains(bytes[1]))
            || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168) { return .privateNetwork }
        if bytes[0] == 127 { return .loopback }
        if bytes[0] == 169 && bytes[1] == 254 { return .linkLocal }
        if (bytes[0] == 192 && bytes[1] == 0 && bytes[2] == 2)
            || (bytes[0] == 198 && bytes[1] == 51 && bytes[2] == 100)
            || (bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113) {
            return .documentation
        }
        if (bytes[0] == 192 && bytes[1] == 0 && bytes[2] == 0)
            || (bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19)) {
            return .reserved
        }
        if bytes[0] >= 224 { return .multicast }
        return .usable
    }

    private static func classifyIPv6(_ data: Data) -> LiveObservedAddressClassification {
        let bytes = [UInt8](data)
        if bytes.allSatisfy({ $0 == 0 }) { return .unspecified }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return .loopback }
        if bytes[0] == 0xff { return .multicast }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return .linkLocal }
        if bytes[0] & 0xfe == 0xfc { return .privateNetwork }
        if bytes[0...3] == [0x20, 0x01, 0x0d, 0xb8] { return .documentation }
        if bytes[0..<10].allSatisfy({ $0 == 0 }),
           bytes[10] == 0xff, bytes[11] == 0xff {
            return classifyIPv4(Data(bytes[12..<16]))
        }
        if bytes[0..<12].allSatisfy({ $0 == 0 }) { return .reserved }
        return .usable
    }
}

public struct LiveObservedAddressFact: Codable, Equatable, Sendable {
    public let family: LiveObservedAddressFamily
    public let classification: LiveObservedAddressClassification
    public let addressDigest: String

    enum CodingKeys: String, CodingKey {
        case family
        case classification
        case addressDigest = "address_digest"
    }

    public init(address: LiveObservedIPAddress, redactionSalt: Data) {
        family = address.family
        classification = address.classification
        addressDigest = ReadinessDigest.salted(address.rawBytes, salt: redactionSalt)
    }
}

public struct LiveObservedPreflightFacts: Codable, Equatable, Sendable {
    public static let schema = "codex-travel-mode-observed-preflight/v1"

    public let schema: String
    public let capturedAtUnixMilliseconds: Int64
    public let sleepDisabled: Bool
    public let battery: LiveObservedBattery
    public let lidClosed: Bool
    public let wifiDevice: String
    public let wifiPowered: Bool
    public let ssidDigest: String
    public let usableAddresses: [LiveObservedAddressFact]
    public let defaultRouteDevice: String
    public let appProcessAbsent: Bool

    enum CodingKeys: String, CodingKey {
        case schema
        case capturedAtUnixMilliseconds = "captured_at_unix_milliseconds"
        case sleepDisabled = "sleep_disabled"
        case battery
        case lidClosed = "lid_closed"
        case wifiDevice = "wifi_device"
        case wifiPowered = "wifi_powered"
        case ssidDigest = "ssid_digest"
        case usableAddresses = "usable_addresses"
        case defaultRouteDevice = "default_route_device"
        case appProcessAbsent = "app_process_absent"
    }

    public init(
        capturedAtUnixMilliseconds: Int64,
        sleepDisabled: Bool,
        battery: LiveObservedBattery,
        lidClosed: Bool,
        wifiDevice: String,
        wifiPowered: Bool,
        ssidDigest: String,
        usableAddresses: [LiveObservedAddressFact],
        defaultRouteDevice: String,
        appProcessAbsent: Bool
    ) throws {
        guard capturedAtUnixMilliseconds >= 0, !wifiDevice.isEmpty,
              LiveProofValidation.isSHA256Hex(ssidDigest),
              !defaultRouteDevice.isEmpty else {
            throw LiveObservedSystemError.malformedOutput("invalid preflight fact")
        }
        schema = Self.schema
        self.capturedAtUnixMilliseconds = capturedAtUnixMilliseconds
        self.sleepDisabled = sleepDisabled
        self.battery = battery
        self.lidClosed = lidClosed
        self.wifiDevice = wifiDevice
        self.wifiPowered = wifiPowered
        self.ssidDigest = ssidDigest
        self.usableAddresses = usableAddresses
        self.defaultRouteDevice = defaultRouteDevice
        self.appProcessAbsent = appProcessAbsent
    }
}

public struct LiveObservedRuntimeNetworkSnapshot: Equatable, Sendable {
    public let capturedAtUnixMilliseconds: Int64
    public let sleepDisabled: Bool
    public let lidClosed: Bool
    public let battery: LiveObservedBattery
    public let ssidDigest: String
    public let wifiDevice: String
    public let wifiPowered: Bool
    public let interfaceAddresses: [LiveObservedIPAddress]
    public let routedRemoteAddress: LiveObservedIPAddress
    public let routeDevice: String

    public init(
        capturedAtUnixMilliseconds: Int64,
        sleepDisabled: Bool,
        lidClosed: Bool,
        battery: LiveObservedBattery,
        ssidDigest: String,
        wifiDevice: String,
        wifiPowered: Bool,
        interfaceAddresses: [LiveObservedIPAddress],
        routedRemoteAddress: LiveObservedIPAddress,
        routeDevice: String
    ) throws {
        guard capturedAtUnixMilliseconds >= 0,
              LiveProofValidation.isSHA256Hex(ssidDigest),
              !wifiDevice.isEmpty, !routeDevice.isEmpty,
              !interfaceAddresses.filter(\.isUsable).isEmpty else {
            throw LiveObservedSystemError.malformedOutput("invalid runtime network snapshot")
        }
        self.capturedAtUnixMilliseconds = capturedAtUnixMilliseconds
        self.sleepDisabled = sleepDisabled
        self.lidClosed = lidClosed
        self.battery = battery
        self.ssidDigest = ssidDigest
        self.wifiDevice = wifiDevice
        self.wifiPowered = wifiPowered
        self.interfaceAddresses = interfaceAddresses
        self.routedRemoteAddress = routedRemoteAddress
        self.routeDevice = routeDevice
    }
}

public enum LiveObservedJournalState: String, Codable, Sendable {
    case present
    case absent
    case unauthorized
    case indeterminate
}

public struct LiveObservedCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct LiveObservedCommandResult: Equatable, Sendable {
    public let exitStatus: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitStatus: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol LiveObservedCommandRunning: Sendable {
    func run(_ command: LiveObservedCommand) throws -> LiveObservedCommandResult
}

public struct LiveObservedCodeIdentity: Equatable, Sendable {
    public let pid: Int32?
    public let processStartIdentity: String?
    public let identifier: String
    public let teamIdentifier: String
    public let cdHash: String
    public let executableURL: URL
    public let designatedRequirement: String

    public init(
        pid: Int32?,
        processStartIdentity: String?,
        identifier: String,
        teamIdentifier: String,
        cdHash: String,
        executableURL: URL,
        designatedRequirement: String
    ) throws {
        guard pid.map({ $0 > 0 }) ?? true,
              !identifier.isEmpty, !teamIdentifier.isEmpty, !cdHash.isEmpty,
              executableURL.path.hasPrefix("/"), !designatedRequirement.isEmpty else {
            throw LiveObservedSystemError.identityMismatch("incomplete code identity")
        }
        self.pid = pid
        self.processStartIdentity = processStartIdentity
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
        self.cdHash = cdHash
        self.executableURL = executableURL.standardizedFileURL
        self.designatedRequirement = designatedRequirement
    }
}

public enum LiveObservedCodeSubject: Equatable, Sendable {
    case runningProcess(pid: Int32)
    case executable(URL)
}

public protocol LiveObservedCodeIdentityInspecting: Sendable {
    func runningIdentity(pid: Int32) throws -> LiveObservedCodeIdentity
    func embeddedIdentity(at url: URL) throws -> LiveObservedCodeIdentity
    func requirementMatches(
        subject: LiveObservedCodeSubject,
        requirement: String
    ) throws -> Bool
}
