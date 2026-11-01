import UIKit
import Capacitor
import WebKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = ExampleViewController()
        window?.makeKeyAndVisible()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}


final class ExampleViewController: CAPBridgeViewController, WKScriptMessageHandler {
    override func webViewConfiguration(for instanceConfiguration: InstanceConfiguration) -> WKWebViewConfiguration {
        let configuration = super.webViewConfiguration(for: instanceConfiguration)
        if ProcessInfo.processInfo.arguments.contains("--ios-stage1-smoke") {
            configuration.userContentController.add(self, name: "stage1")
            configuration.userContentController.addUserScript(WKUserScript(source: "localStorage.setItem('lt.e2e', '1');", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            configuration.userContentController.addUserScript(WKUserScript(source: "var s = document.createElement('script'); s.src = 'ios-smoke.js'; document.body.appendChild(s);", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        return configuration
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "stage1", let body = message.body as? [String: Any] else { return }
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            try data.write(to: directory.appendingPathComponent("ios-stage1-smoke.json"), options: .atomic)
        } catch { assertionFailure("Could not save simulator smoke results") }
    }
}
