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
        refreshClaims(pairingClaim: Self.isPairingClaimPush(userInfo))
        return .newData
    }

    /// A pairing-claim push proves a claim exists server-side, so its
    /// refresh insists (retry with backoff) — the fetch it triggers often
    /// races a cold-started radio, and a single silent failure was how a
    /// tapped notification could open the app to no card. Other push kinds
    /// keep the single best-effort refresh.
    private func refreshClaims(pairingClaim: Bool) {
        if pairingClaim {
            services.refreshPendingReverseClaimsExpectingClaim()
        } else {
            services.refreshPendingReverseClaims()
        }
    }

    /// Parsed outside any actor hop: `userInfo` is not Sendable, so only
    /// this Bool crosses into the main-actor refresh.
    nonisolated static func isPairingClaimPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["ttybuild"] as? [AnyHashable: Any])?["kind"] as? String
            == "reverse-pairing-claim"
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
        let pairingClaim = Self.isPairingClaimPush(
            notification.request.content.userInfo
        )
        Task { @MainActor in
            self.refreshClaims(pairingClaim: pairingClaim)
        }
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let pairingClaim = Self.isPairingClaimPush(
            response.notification.request.content.userInfo
        )
        Task { @MainActor in
            self.refreshClaims(pairingClaim: pairingClaim)
        }
        completionHandler()
    }
}
