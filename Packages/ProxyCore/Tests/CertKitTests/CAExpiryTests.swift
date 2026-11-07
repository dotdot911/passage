import CertKit
import Foundation
import Testing

@Suite struct CAExpiryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func farFromTheEndIsValid() {
        #expect(CAExpiry.of(notAfter: now.addingTimeInterval(31 * 86_400), now: now) == .valid)
        #expect(CAExpiry.of(notAfter: now.addingTimeInterval(2 * 365 * 86_400), now: now) == .valid)
    }

    @Test func lastThirtyDaysWarn() {
        #expect(CAExpiry.of(notAfter: now.addingTimeInterval(30 * 86_400), now: now) == .expiresSoon(days: 30))
        #expect(CAExpiry.of(notAfter: now.addingTimeInterval(3_600), now: now) == .expiresSoon(days: 1))
    }

    @Test func pastTheEndIsExpired() {
        #expect(CAExpiry.of(notAfter: now, now: now) == .expired)
        #expect(CAExpiry.of(notAfter: now.addingTimeInterval(-86_400), now: now) == .expired)
    }

    @Test func generatedCAIsValid() throws {
        let ca = try CertificateAuthority.generate(now: now)
        #expect(CAExpiry.of(notAfter: ca.certificate.notValidAfter, now: now) == .valid)
    }
}
