import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    registerThermalChannel()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Camera Mode's health reports read how hot the phone is running from
  /// here (lib/health/health_monitor.dart). iOS only exposes a level, not
  /// degrees; its names are the ones the server stores.
  private func registerThermalChannel() {
    guard let registrar = registrar(forPlugin: "KeepWatchThermal") else { return }
    let channel = FlutterMethodChannel(name: "keepwatch/thermal", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "thermalState" else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch ProcessInfo.processInfo.thermalState {
      case .nominal: result("nominal")
      case .fair: result("fair")
      case .serious: result("serious")
      case .critical: result("critical")
      @unknown default: result(nil)
      }
    }
  }
}
