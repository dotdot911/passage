import Crypto
import Foundation
import NIOSSL
import ProxyModel
import SwiftASN1
import X509

/// The Passage root CA plus an LRU cache of per-host leaf certificates.
public final class CertificateAuthority: @unchecked Sendable {
    public let certificate: Certificate
    private let privateKey: P256.Signing.PrivateKey
    private let leafKey = P256.Signing.PrivateKey()
    private let lock = NSLock()
    private var cache: [String: NIOSSLContext] = [:]
    private var order: [String] = []
    private let cacheLimit: Int

    public init(certificate: Certificate, privateKey: P256.Signing.PrivateKey, cacheLimit: Int = 64) {
        self.certificate = certificate
        self.privateKey = privateKey
        self.cacheLimit = cacheLimit
    }

    /// Creates a fresh root CA valid for 2 years.
    public static func generate(commonName: String = "Passage CA", now: Date = Date()) throws -> CertificateAuthority {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName {
            CommonName(commonName)
            OrganizationName("Passage")
        }
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: .init(key.publicKey),
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(2 * 365 * 86_400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(digitalSignature: true, keyCertSign: true, cRLSign: true))
                SubjectKeyIdentifier(hash: .init(key.publicKey))
            },
            issuerPrivateKey: .init(key))
        return CertificateAuthority(certificate: cert, privateKey: key)
    }

    /// DER bytes of the root certificate (what the user installs as a profile).
    public func rootDER() throws -> [UInt8] {
        var s = DER.Serializer()
        try s.serialize(certificate)
        return s.serializedBytes
    }

    /// Raw private key bytes for Keychain storage.
    public var privateKeyRaw: Data { privateKey.rawRepresentation }

    /// Signs a leaf certificate for `host` (DNS name or IP literal), valid 1 year.
    public func issueLeaf(for host: String, now: Date = Date()) throws -> Certificate {
        let san: GeneralName
        if let ip = IPAddressBytes(host) { san = .ipAddress(ASN1OctetString(contentBytes: ArraySlice(ip))) } else { san = .dnsName(host) }
        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: .init(leafKey.publicKey),
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(365 * 86_400),
            issuer: certificate.subject,
            subject: try DistinguishedName { CommonName(String(host.prefix(64))) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([san])
                AuthorityKeyIdentifier(keyIdentifier: try certificate.extensions.subjectKeyIdentifier?.keyIdentifier)
            },
            issuerPrivateKey: .init(privateKey))
    }

    /// Drops all but the `count` most recently used leaf contexts (low-memory mode).
    public func trimCache(to count: Int) {
        lock.lock(); defer { lock.unlock() }
        while order.count > count { cache.removeValue(forKey: order.removeFirst()) }
    }

    /// A cached TLS server context presenting a leaf for `host` with the given ALPN list.
    public func serverContext(for host: String, alpn: [String]) throws -> NIOSSLContext {
        let key = host + "|" + alpn.joined(separator: ",")
        lock.lock(); defer { lock.unlock() }
        if let ctx = cache[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return ctx
        }
        let leaf = try issueLeaf(for: host)
        var s = DER.Serializer()
        try s.serialize(leaf)
        var config = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: s.serializedBytes, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(leafKey.derRepresentation), format: .der)))
        config.applicationProtocols = alpn
        let ctx = try NIOSSLContext(configuration: config)
        cache[key] = ctx
        order.append(key)
        if order.count > cacheLimit { cache.removeValue(forKey: order.removeFirst()) }
        return ctx
    }
}

