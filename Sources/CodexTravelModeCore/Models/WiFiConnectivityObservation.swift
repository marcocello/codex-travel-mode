import Darwin
import Foundation

public enum ConnectivityProviderFailureCategory: String, Codable, Equatable, Sendable {
    case timedOut = "timed_out"
    case commandFailed = "command_failed"
    case malformedOutput = "malformed_output"
    case unavailable
}

public struct ConnectivityProviderFailure: Error, Codable, Equatable, Sendable {
    public let category: ConnectivityProviderFailureCategory
    public let detail: String

    public init(category: ConnectivityProviderFailureCategory, detail: String) {
        self.category = category
        self.detail = detail
    }
}

public enum ProviderReading<Value: Equatable & Sendable>: Equatable, Sendable {
    case value(Value)
    case failure(ConnectivityProviderFailure)

    public var value: Value? {
        guard case let .value(value) = self else {
            return nil
        }
        return value
    }

    public var failure: ConnectivityProviderFailure? {
        guard case let .failure(failure) = self else {
            return nil
        }
        return failure
    }
}

public enum LidState: String, Codable, Equatable, Sendable {
    case open
    case closed
}

public enum IPAddressFamily: String, Codable, Equatable, Sendable {
    case ipv4
    case ipv6
}

public struct IPAddress: Codable, Equatable, Sendable {
    public let rawValue: String
    public let family: IPAddressFamily
    public let isUsable: Bool

    public init?(_ rawValue: String) {
        let address = rawValue.split(separator: "%", maxSplits: 1).first.map(String.init) ?? rawValue

        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            self.rawValue = address
            family = .ipv4
            isUsable = Self.isUsableIPv4(ipv4)
            return
        }

        var ipv6 = in6_addr()
        if address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            self.rawValue = address
            family = .ipv6
            isUsable = Self.isUsableIPv6(ipv6)
            return
        }

        return nil
    }

    private static func isUsableIPv4(_ address: in_addr) -> Bool {
        let hostValue = UInt32(bigEndian: address.s_addr)
        let first = UInt8((hostValue >> 24) & 0xff)
        let second = UInt8((hostValue >> 16) & 0xff)

        // 0/8 is reserved, 127/8 is loopback, 169.254/16 is link-local,
        // and 224/4 and above are multicast or reserved rather than unicast.
        return first != 0
            && first != 127
            && !(first == 169 && second == 254)
            && first < 224
    }

    private static func isUsableIPv6(_ address: in6_addr) -> Bool {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        let isUnspecified = bytes.allSatisfy { $0 == 0 }
        let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        let isMulticast = bytes.first == 0xff
        let isLinkLocal = bytes.count >= 2
            && bytes[0] == 0xfe
            && (bytes[1] & 0xc0) == 0x80
        return !isUnspecified && !isLoopback && !isMulticast && !isLinkLocal
    }
}

public struct WiFiConnectivityObservation: Equatable, Sendable {
    public let device: String
    public let power: ProviderReading<Bool>
    public let ssid: ProviderReading<ExactUTF8String?>
    public let addresses: ProviderReading<[IPAddress]>
    public let defaultRouteInterface: ProviderReading<String?>

    public init(
        device: String,
        power: ProviderReading<Bool>,
        ssid: ProviderReading<ExactUTF8String?>,
        addresses: ProviderReading<[IPAddress]>,
        defaultRouteInterface: ProviderReading<String?>
    ) {
        self.device = device
        self.power = power
        self.ssid = ssid
        self.addresses = addresses
        self.defaultRouteInterface = defaultRouteInterface
    }

    /// `nil` means the address provider failed, rather than reporting no usable address.
    public var hasUsableAddress: Bool? {
        addresses.value?.contains(where: \.isUsable)
    }
}
