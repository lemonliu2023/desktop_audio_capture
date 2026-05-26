import Cocoa
import FlutterMacOS

public class AudioCapturePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "audio_capture", binaryMessenger: registrar.messenger)
    let instance = AudioCapturePlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)

    // Register the microphone plugin
    MicCapturePlugin.register(with: registrar)

    // Register the system audio plugin (Core Audio Process Tap requires macOS 14.2+).
    if #available(macOS 14.2, *) {
      SystemCapturePlugin.register(with: registrar)
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
