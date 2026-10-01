import Foundation
import Security

struct PasscodeManager {
    private static let service = "com.alexintosh.Specchio"
    private static let account = "devicePasscode"
    var store = SpecchioKeychainStore.shared

    @discardableResult
    func save(passcode: String) -> Bool {
        store.write(service: Self.service, account: Self.account,
                    data: Data(passcode.utf8), allowUI: true) == errSecSuccess
    }

    func load(allowAuthenticationUI: Bool = false) -> String? {
        let result = store.read(service: Self.service, account: Self.account, allowUI: allowAuthenticationUI)
        return result.data.flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    func delete() -> Bool {
        let status = store.delete(service: Self.service, account: Self.account, allowUI: true)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    var hasSavedPasscode: Bool {
        store.contains(service: Self.service, account: Self.account)
    }
}
