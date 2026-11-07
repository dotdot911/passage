import Foundation

/// Builds the `.mobileconfig` that installs the root CA on iOS.
public enum ProfileBuilder {
    public static func rootProfile(der: [UInt8], identifier: String = "com.passage.io.ca") throws -> Data {
        let payload: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier + ".cert",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "Passage CA",
            "PayloadContent": Data(der),
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier,
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "Passage CA",
            "PayloadDescription": "Lets Passage decrypt HTTPS traffic on this device. The key never leaves the device.",
            "PayloadContent": [payload],
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }
}
