import Cocoa
import FlutterMacOS
import Sparkle

class MainFlutterWindow: NSWindow {
  private var updater: UpdaterBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // AppKit saves and restores the size and position under this name.
    self.setFrameAutosaveName("EveryAIMainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)
    updater = UpdaterBridge(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// In-place updates through Sparkle, driven from Dart (`lib/features/updates/data/sparkle_updater.dart`).
///
/// Dart picks the release (its channel setting decides pre-releases) and hands over that release's appcast; Sparkle
/// downloads it quietly, checks the EdDSA signature (SUPublicEDKey) and the code signature, and holds the install.
/// "Restart to update" in the app runs the held install, which swaps the bundle and relaunches. Unsigned or
/// differently signed builds report themselves unavailable and never update.
final class UpdaterBridge: NSObject, SPUUpdaterDelegate {
  /// The team the release is signed by; any other signature (a local or dev build) turns updates off.
  private static let releaseTeam = "2MGLZ5685D"
  private static let feedKey = "EveryAIUpdateFeed"

  private let channel: FlutterMethodChannel
  private var controller: SPUStandardUpdaterController?
  private var installNow: (() -> Void)?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "everyai/updater", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
  }

  private func handle(_ call: FlutterMethodCall, _ result: FlutterResult) {
    switch call.method {
    case "available":
      result(UpdaterBridge.signedByReleaseTeam())
    case "check":
      guard UpdaterBridge.signedByReleaseTeam() else { return result(false) }
      if let feed = (call.arguments as? [String: Any])?["feed"] as? String {
        UserDefaults.standard.set(feed, forKey: UpdaterBridge.feedKey)
      }
      if controller == nil {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
          try controller!.updater.start()
        } catch {
          controller = nil
          return result(FlutterError(code: "start", message: error.localizedDescription, details: nil))
        }
        controller!.updater.automaticallyChecksForUpdates = true
        controller!.updater.automaticallyDownloadsUpdates = true
      }
      if installNow != nil { return result(true) }
      controller!.updater.checkForUpdatesInBackground()
      result(true)
    case "installNow":
      guard let install = installNow else { return result(false) }
      result(true)
      install()
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func feedURLString(for updater: SPUUpdater) -> String? {
    UserDefaults.standard.string(forKey: UpdaterBridge.feedKey)
  }

  func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock: @escaping () -> Void
  ) -> Bool {
    installNow = immediateInstallationBlock
    channel.invokeMethod("ready", arguments: ["version": item.displayVersionString])
    return true
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
    channel.invokeMethod("none", arguments: nil)
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    let e = error as NSError
    // "No update" also arrives here as an error code; it isn't a failure.
    if e.domain == SUSparkleErrorDomain && e.code == Int(SUError.noUpdateError.rawValue) { return }
    channel.invokeMethod("error", arguments: error.localizedDescription)
  }

  private static func signedByReleaseTeam() -> Bool {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
      == errSecSuccess, let dict = info as? [String: Any]
    else { return false }
    return dict[kSecCodeInfoTeamIdentifier as String] as? String == releaseTeam
  }
}
