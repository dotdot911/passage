import Crypto
import Foundation
import Security
import SwiftASN1
import X509

/// Persists the root CA (certificate + private key) in the Keychain group shared by the
/// app and the extension. The key is `ThisDeviceOnly`: it never syncs or leaves the device.
public struct CAStore: Sendable {
    public let service: String
    /// e.g. "ABCDE12345.com.passage.io.shared"; nil uses the default group (tests on macOS).
    public let accessGroup: String?

    public init(service: String = "com.passage.io.ca", accessGroup: String?) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// Reads the stored CA, or generates and stores a new one.
    public func loadOrCreate() throws -> CertificateAuthority {
        if let ca = try load() { return ca }
        let ca = try CertificateAuthority.generate()
        try save(ca)
        return ca
    }

    public func load() throws -> CertificateAuthority? {
        guard let keyData = try read(account: "root-key"), let certData = try read(account: "root-cert") else { return nil }
        let key = try P256.Signing.PrivateKey(rawRepresentation: keyData)
        let cert = try Certificate(derEncoded: Array(certData))
        return CertificateAuthority(certificate: cert, privateKey: key)
    }

    public func save(_ ca: CertificateAuthority) throws {
        try write(account: "root-key", data: ca.privateKeyRaw)
        try write(account: "root-cert", data: Data(try ca.rootDER()))
    }

    /// Deletes the CA; the next `loadOrCreate` makes a new one (Settings → Regenerate CA).
    public func delete() throws {
        for account in ["root-key", "root-cert"] {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    private func read(account: String) throws -> Data? {
        var q = baseQuery(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return out as? Data
    }

    private func write(account: String, data: Data) throws {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var q = baseQuery(account: account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String { "Keychain error \(status)" }
}
