import GhosttyTerminal
import UIKit
import UserNotifications

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    lazy var services = AppServices()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if ProcessInfo.processInfo.environment["TTYBUILD_GHOSTTY_DEBUG"] != nil {
            TerminalDebugLog.isEnabled = true
            TerminalDebugLog.categories = .all
        }
        UNUserNotificationCenter.current().delegate = self
        services.startSystemSurfaces()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }

    // MARK: - Remote notifications (reverse-pairing claims)

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        services.handlePushDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Simulators and denied permissions land here; polling on launch and
        // foreground still surfaces pending claims.
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        services.refreshPendingReverseClaims()
        return .newData
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// A pairing-claim alert stays useful while the app is frontmost — the
    /// confirmation card appears from the same refresh the banner announces.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            self.services.refreshPendingReverseClaims()
        }
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            self.services.refreshPendingReverseClaims()
        }
        completionHandler()
    }
}
