import Foundation

/// How close the root CA is to its `notValidAfter` date.
public enum CAExpiry: Equatable, Sendable {
    case valid
    case expiresSoon(days: Int)
    case expired

    /// The app starts warning this many days before the end date.
    public static let warningDays = 30

    public static func of(notAfter: Date, now: Date = Date()) -> CAExpiry {
        let remaining = notAfter.timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        let days = Int((remaining / 86_400).rounded(.up))
        return days <= warningDays ? .expiresSoon(days: days) : .valid
    }
}
