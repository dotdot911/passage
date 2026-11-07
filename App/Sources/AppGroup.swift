import Foundation
import IPC

/// Locations shared by the app and the extension.
enum AppGroup {
    static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: IPCConstants.appGroup)!
            .appendingPathComponent("Data", isDirectory: true)
    }

    /// "$(AppIdentifierPrefix)com.passage.io.shared", expanded at build time into Info.plist.
    static var keychainAccessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "KeychainAccessGroup") as? String
    }
}

extension AppGroup {
    static var tunnelLogURL: URL { containerURL.appendingPathComponent("tunnel.log") }
}
