import Foundation
import Security

public protocol KeychainPasswordStoring: Sendable {
    func readPassword(account: String) throws -> String
    func savePassword(_ password: String, account: String) throws
    func passwordExists(account: String) throws -> Bool
    func deletePassword(account: String) throws
}

public extension KeychainPasswordStoring {
    func passwordExists(account: String) throws -> Bool {
        do {
            return !(try readPassword(account: account)).isEmpty
        } catch KeychainError.notFound {
            return false
        }
    }

    func deletePassword(account: String) throws {
        throw KeychainError.deleteUnsupported
    }
}

public final class KeychainPasswordStore: KeychainPasswordStoring, @unchecked Sendable {
    private let service: String

    public init(service: String = "CodexTravelMode") {
        self.service = service
    }

    public func readPassword(account: String) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard status == errSecSuccess, let data = result as? Data else {
            throw Self.typedReadError(status)
        }
        guard let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidPasswordData
        }
        return password
    }

    public func savePassword(_ password: String, account: String) throws {
        guard !password.isEmpty else { throw KeychainError.emptyPassword }
        var item = baseQuery(account: account)
        item[kSecValueData as String] = Data(password.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let existing = try readPassword(account: account)
            guard existing.hasExactUTF8Representation(as: password) else {
                throw KeychainError.credentialConflict
            }
            return
        }
        guard status == errSecSuccess else { throw KeychainError.saveFailed(status) }
    }

    public func passwordExists(account: String) throws -> Bool {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw Self.typedReadError(status) }
        return true
    }

    public func deletePassword(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func typedReadError(_ status: OSStatus) -> KeychainError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable:
            .inaccessible(status)
        case errSecAuthFailed, errSecUserCanceled, errSecMissingEntitlement:
            .denied(status)
        case errSecDecode:
            .corruptData(status)
        default:
            .readFailed(status)
        }
    }
}

public enum KeychainError: LocalizedError, Equatable, Sendable {
    case notFound
    case inaccessible(OSStatus)
    case denied(OSStatus)
    case corruptData(OSStatus)
    case emptyPassword
    case invalidPasswordData
    case credentialConflict
    case readFailed(OSStatus)
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case deleteUnsupported

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "The hotspot password was not found in Keychain."
        case .inaccessible(let status):
            "Keychain is unavailable or locked (status \(status))."
        case .denied(let status):
            "Keychain access was denied (status \(status))."
        case .corruptData(let status):
            "The hotspot credential is corrupt (status \(status))."
        case .emptyPassword:
            "An empty hotspot password cannot be stored in Keychain."
        case .invalidPasswordData:
            "The hotspot password in Keychain is not valid UTF-8 data."
        case .credentialConflict:
            "The revision-specific Keychain item already contains another credential."
        case .readFailed(let status):
            "Could not read the hotspot password from Keychain (status \(status))."
        case .saveFailed(let status):
            "Could not save the hotspot password to Keychain (status \(status))."
        case .deleteFailed(let status):
            "Could not delete the hotspot password from Keychain (status \(status))."
        case .deleteUnsupported:
            "This Keychain provider does not support credential deletion."
        }
    }
}
