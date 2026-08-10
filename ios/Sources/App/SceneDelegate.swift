import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var services: AppServices?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        let services = appDelegate.services
        self.services = services

        let window = UIWindow(windowScene: windowScene)
        // TTYBuild has a fixed black-and-white shell. Terminal ANSI colors stay
        // inside the terminal canvas and never become application chrome.
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = TTYBuildTheme.uiCanvas
        window.tintColor = TTYBuildTheme.uiContent
        window.rootViewController = MainViewController(services: services)
        window.makeKeyAndVisible()
        self.window = window

    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        services?.terminals.kickAll()
        services?.refreshStatusSurfaces()
    }
}
