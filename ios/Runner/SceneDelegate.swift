import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    if !connectionOptions.urlContexts.isEmpty {
      SharedMediaBridge.shared.ingest(urlContexts: connectionOptions.urlContexts)
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  override func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    if !URLContexts.isEmpty {
      SharedMediaBridge.shared.ingest(urlContexts: URLContexts)
    }
    super.scene(scene, openURLContexts: URLContexts)
  }
}
