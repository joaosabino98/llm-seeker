//
//  Keychain.swift
//  LLM Seeker
//

import Foundation

enum KeychainError: Error, LocalizedError {
    case saveFailed
    case loadFailed
    case deleteFailed
    case itemNotFound
    case unsupportedData

    var errorDescription: String? {
        switch self {
        case .saveFailed: return "Failed to save item to Keychain"
        case .loadFailed: return "Failed to load item from Keychain"
        case .deleteFailed: return "Failed to delete item from Keychain"
        case .itemNotFound: return "Item not found in Keychain"
        case .unsupportedData: return "Unsupported data format"
        }
    }
}

struct KeychainService {
    private static let bundleIdentifier = "com.joaosabino.LLM-Seeker"

    static func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.unsupportedData }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: bundleIdentifier,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.saveFailed }
    }

    static func load(key: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: bundleIdentifier,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound { throw KeychainError.itemNotFound }
            throw KeychainError.loadFailed
        }
        guard let string = String(data: data, encoding: .utf8) else { throw KeychainError.unsupportedData }
        return string
    }

    static func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: bundleIdentifier
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.deleteFailed }
    }

    static func exists(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: bundleIdentifier
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
}

extension KeychainService {
    static var huggingFaceToken: String? {
        get { try? load(key: "huggingface_token") }
        set {
            if let token = newValue { try? save(key: "huggingface_token", value: token) }
            else { try? delete(key: "huggingface_token") }
        }
    }

    static func hasHuggingFaceToken() -> Bool { exists(key: "huggingface_token") }
}
