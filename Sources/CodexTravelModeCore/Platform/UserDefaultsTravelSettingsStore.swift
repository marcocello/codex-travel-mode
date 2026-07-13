import Foundation
import Security

public final class UserDefaultsTravelSettingsStore: TravelSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let keychain: KeychainPasswordStoring
    private let hotspotSSIDKey = "fallbackHotspotSSID"
    private let wifiDeviceKey = "wifiDevice"
    private let passwordSavedKey = "fallbackHotspotPasswordSaved"
    private let restoreSnapshotKey = "activeRestoreSnapshot"
    private let passwordAccount = "fallbackHotspotPassword"

    public init(
        defaults: UserDefaults = .standard,
        keychain: KeychainPasswordStoring = KeychainPasswordStore()
    ) {
        self.defaults = defaults
        self.keychain = keychain
    }

    public func load() -> TravelModeSettings {
        TravelModeSettings(
            hotspotSSID: defaults.string(forKey: hotspotSSIDKey) ?? "iPhone",
            hotspotPassword: "",
            wifiDevice: defaults.string(forKey: wifiDeviceKey) ?? ""
        )
    }

    public func loadHotspotPassword() throws -> String {
        try keychain.readPassword(account: passwordAccount)
    }

    public func hasSavedHotspotPassword() -> Bool {
        defaults.bool(forKey: passwordSavedKey)
    }

    public func save(_ settings: TravelModeSettings) throws {
        defaults.set(settings.hotspotSSID, forKey: hotspotSSIDKey)
        defaults.set(settings.wifiDevice, forKey: wifiDeviceKey)
        let password = settings.trimmedHotspotPassword
        if !password.isEmpty {
            try keychain.savePassword(password, account: passwordAccount)
            defaults.set(true, forKey: passwordSavedKey)
        }
    }

    public func loadRestoreSnapshot() -> TravelRestoreSnapshot? {
        guard let data = defaults.data(forKey: restoreSnapshotKey) else {
            return nil
        }
        return try? JSONDecoder().decode(TravelRestoreSnapshot.self, from: data)
    }

    public func saveRestoreSnapshot(_ snapshot: TravelRestoreSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }
        defaults.set(data, forKey: restoreSnapshotKey)
    }

    public func clearRestoreSnapshot() {
        defaults.removeObject(forKey: restoreSnapshotKey)
    }
}

public protocol KeychainPasswordStoring: Sendable {
    func readPassword(account: String) throws -> String
    func savePassword(_ password: String, account: String) throws
}

public final class KeychainPasswordStore: KeychainPasswordStoring, @unchecked Sendable {
    private let service = "CodexTravelMode"

    public init() {}

    public func readPassword(account: String) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    public func savePassword(_ password: String, account: String) throws {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)

        guard !password.isEmpty else {
            return
        }

        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Could not save hotspot password to Keychain (status \(status))."
        }
    }
}
