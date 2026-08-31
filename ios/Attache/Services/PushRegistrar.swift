import Foundation

/// App-wide seam for push registrations. The APNs device token arrives via
/// the UIApplicationDelegate (separate process boundary), and Live Activity
/// push-to-start tokens arrive from ActivityKit — neither knows about the
/// bridge. BridgeEngine subscribes once at startup and forwards every
/// registration over each paired machine's socket; the bridge persists the
/// targets and the stateless relay delivers while the app is suspended.
@MainActor
final class PushRegistrar {
    static let shared = PushRegistrar()

    private(set) var deviceToken: String?
    /// Set by BridgeEngine; receives (transport, target) for every new token.
    var onRegister: ((_ transport: String, _ target: String) -> Void)?

    func setDeviceToken(_ token: String) {
        deviceToken = token
        onRegister?("apns", token)
    }

    /// Live Activity push-to-start token (contract H seam — the relay
    /// delivers live-activity pushes in a later wave).
    func registerLiveActivityPushToStart(_ token: String) {
        onRegister?("liveactivity", token)
    }
}
