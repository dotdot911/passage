import Foundation
import os
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

/// Append-only log in the App Group, rotated at 5 MB, so the app can show why the tunnel stopped.
enum TunnelLog {
    static let maxBytes = 5 * 1024 * 1024
    private static let queue = DispatchQueue(label: "passage.log")

    static var url: URL { AppGroup.containerURL.appendingPathComponent("tunnel.log") }

    private static let logger = Logger(subsystem: "com.passage.io.tunnel", category: "tunnel")

    static func write(_ line: String) {
        // Lines name the hosts the user visits, so only debug builds show them in the system log.
        #if DEBUG
        logger.notice("\(line, privacy: .public)")
        #else
        logger.notice("\(line, privacy: .private)")
        #endif
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        queue.async {
            let fm = FileManager.default
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxBytes {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(text.utf8))
        }
    }
}
