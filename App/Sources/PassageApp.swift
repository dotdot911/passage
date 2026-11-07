import SwiftUI
import TipKit
import UIKit
import UserNotifications

@main
struct PassageApp: App {
    @State private var model = AppModel()
    @State private var themes = ThemeStore()
    @State private var notifications = NotificationDelegate()

    init() {
        // One-line fields (hosts, names, targets) get the system clear button while editing.
        UITextField.appearance().clearButtonMode = .whileEditing
        #if DEBUG
        if MockTraffic.isScreenshot { Tips.hideAllTipsForTesting() }
        #endif
        try? Tips.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .themed(themes.theme)
                .environment(themes)
                .environment(model)
                .task {
                    notifications.model = model
                    UNUserNotificationCenter.current().delegate = notifications
                    await model.onAppear()
                }
                .onOpenURL { url in Task { await model.importArchive(from: url) } }
        }
    }
}

/// Tapping a breakpoint notification opens that message's editor. In the foreground the breakpoint bar already shows it.
@MainActor
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var model: AppModel?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        await open(id)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.list]
    }

    private func open(_ id: String) async {
        await model?.openBreakpoint(id: id)
    }
}
