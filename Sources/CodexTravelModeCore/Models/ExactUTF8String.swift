import Foundation

/// A text value whose identity is its original UTF-8 byte sequence.
///
/// Swift `String` equality deliberately considers canonically equivalent text
/// equal. Wi-Fi SSIDs do not: the bytes advertised by the access point are the
/// identity, so callers must compare this value instead of its display string.
public struct ExactUTF8String: Equatable, Hashable, Sendable, Codable {
    public let utf8Bytes: Data

    public init?(_ stringValue: String) {
        guard !stringValue.isEmpty else {
            return nil
        }
        utf8Bytes = Data(stringValue.utf8)
    }

    public init?(utf8Bytes: Data) {
        guard !utf8Bytes.isEmpty, String(data: utf8Bytes, encoding: .utf8) != nil else {
            return nil
        }
        self.utf8Bytes = utf8Bytes
    }

    public var stringValue: String {
        // Construction guarantees that the bytes are valid UTF-8.
        String(decoding: utf8Bytes, as: UTF8.self)
    }
}

public extension String {
    func hasExactUTF8Representation(as other: String) -> Bool {
        Data(utf8) == Data(other.utf8)
    }
}
