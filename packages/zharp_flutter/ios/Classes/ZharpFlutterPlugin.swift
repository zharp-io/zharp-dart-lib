import Flutter
import UIKit

/// What the Dart side can't learn by itself: the device model, the iOS version, the app's version,
/// and an install ID kept in the app's own UserDefaults.
///
/// The install ID is random and scoped to this install — not a hardware or advertising ID — so it
/// resets when the app is reinstalled, and needs no permission or tracking disclosure.
public class ZharpFlutterPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "io.zharp/flutter", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(ZharpFlutterPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "deviceInfo" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let device = UIDevice.current
    let bundle = Bundle.main
    var info: [String: Any] = [
      "model": ZharpFlutterPlugin.modelIdentifier(),
      "manufacturer": "Apple",
      "osName": device.systemName,
      "osVersion": device.systemVersion,
      "installId": ZharpFlutterPlugin.installId(),
    ]
    if let id = bundle.bundleIdentifier { info["appId"] = id }
    if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { info["appVersion"] = version }
    if let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String { info["appBuild"] = build }
    result(info)
  }

  /// "iPhone15,2" — on a simulator, the device it simulates.
  private static func modelIdentifier() -> String {
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
    var systemInfo = utsname()
    uname(&systemInfo)
    let machine = withUnsafeBytes(of: &systemInfo.machine) { raw in
      String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return machine.isEmpty ? UIDevice.current.model : machine
  }

  private static func installId() -> String {
    let defaults = UserDefaults.standard
    let key = "io.zharp.install_id"
    if let id = defaults.string(forKey: key) { return id }
    let id = UUID().uuidString.lowercased()
    defaults.set(id, forKey: key)
    return id
  }
}
