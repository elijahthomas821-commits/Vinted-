import Foundation
import Security

enum APIKeyKind: String, CaseIterable, Sendable {
    case openAI = "openai-api-key"
    case anthropic = "anthropic-api-key"

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }
}

protocol APIKeyStore: Sendable {
    func apiKey(for kind: APIKeyKind) -> String?
    /// Saves the key, or deletes it when `value` is `nil` or blank.
    func setAPIKey(_ value: String?, for kind: APIKeyKind) throws
}

struct KeychainError: LocalizedError, Equatable {
    let status: OSStatus

    var errorDescription: String? {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        return "Keychain error: \(message)"
    }
}

/// Stores API keys as generic passwords in the user's login Keychain.
struct KeychainStore: APIKeyStore {
    var service = "com.lecturemind.app.api-keys"

    func apiKey(for kind: APIKeyKind) -> String? {
        var query = baseQuery(for: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    func setAPIKey(_ value: String?, for kind: APIKeyKind) throws {
        let query = baseQuery(for: kind)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !trimmed.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError(status: status)
            }
            return
        }

        let data = Data(trimmed.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrLabel as String] = "LectureMind \(kind.displayName) API Key"
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(for kind: APIKeyKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
        ]
    }
}
