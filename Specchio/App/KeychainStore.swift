import Foundation
import Security
import os.log

/// Explicit user actions may authenticate. Background work always fails quietly
/// when access needs approval; callers must not treat that as an absent item.
final class SpecchioKeychainStore {
    enum Operation { case read, update, add, delete }
    typealias Execute = (Operation, CFDictionary, CFDictionary?, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    static let shared = SpecchioKeychainStore()
    private let backend: Execute
    private static let interactionLock = NSLock()
    private let logger = Logger(subsystem: "com.alexintosh.Specchio", category: "Keychain")

    init(execute: @escaping Execute = { operation, query, attributes, result in
        switch operation {
        case .read: return SecItemCopyMatching(query, result)
        case .update: return SecItemUpdate(query, attributes!)
        case .add: return SecItemAdd(query, result)
        case .delete: return SecItemDelete(query)
        }
    }) { self.backend = execute }

    // These items live in the legacy login keychain. Per-query authentication
    // flags alone do not suppress its ACL dialogs. Serialize the process-wide
    // legacy interaction setting and restore it before returning (no async work).
    private func execute(_ operation: Operation, _ query: CFDictionary,
                         _ attributes: CFDictionary?, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        Self.interactionLock.lock()
        defer { Self.interactionLock.unlock() }
        let request = query as NSDictionary
        let allowsUI = (request[kSecUseAuthenticationUI] as? String) == (kSecUseAuthenticationUIAllow as String)
        var previous: DarwinBoolean = false
        let readStatus = SecKeychainGetUserInteractionAllowed(&previous)
        guard readStatus == errSecSuccess else {
            logger.error("[Keychain] cannot inspect interaction policy status=\(readStatus)")
            return readStatus
        }
        let setStatus = SecKeychainSetUserInteractionAllowed(allowsUI)
        guard setStatus == errSecSuccess else {
            logger.error("[Keychain] cannot set interaction policy status=\(setStatus)")
            return setStatus
        }
        defer {
            let restoreStatus = SecKeychainSetUserInteractionAllowed(previous.boolValue)
            if restoreStatus != errSecSuccess { logger.error("[Keychain] interaction policy restore failed status=\(restoreStatus)") }
        }
        return backend(operation, query, attributes, result)
    }

    private func query(service: String, account: String, allowUI: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecUseAuthenticationUI as String: allowUI ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail]
    }

    func read(service: String, account: String, allowUI: Bool = false) -> (status: OSStatus, data: Data?) {
        var request = query(service: service, account: account, allowUI: allowUI)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = execute(.read, request as CFDictionary, nil, &result)
        logger.info("[Keychain] read account=\(account, privacy: .public) interactive=\(allowUI) status=\(status)")
        return (status, status == errSecSuccess ? result as? Data : nil)
    }

    func contains(service: String, account: String) -> Bool {
        var request = query(service: service, account: account, allowUI: false)
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = execute(.read, request as CFDictionary, nil, nil)
        logger.info("[Keychain] existence account=\(account, privacy: .public) interactive=false status=\(status)")
        return status == errSecSuccess
    }

    func write(service: String, account: String, data: Data, allowUI: Bool) -> OSStatus {
        var request = query(service: service, account: account, allowUI: allowUI)
        let attributes = [kSecValueData as String: data] as CFDictionary
        var status = execute(.update, request as CFDictionary, attributes, nil)
        if status == errSecItemNotFound {
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = execute(.add, request as CFDictionary, nil, nil)
        }
        logger.info("[Keychain] write account=\(account, privacy: .public) interactive=\(allowUI) status=\(status)")
        return status
    }

    func delete(service: String, account: String, allowUI: Bool) -> OSStatus {
        let status = execute(.delete, query(service: service, account: account, allowUI: allowUI) as CFDictionary, nil, nil)
        logger.info("[Keychain] delete account=\(account, privacy: .public) interactive=\(allowUI) status=\(status)")
        return status
    }
}
