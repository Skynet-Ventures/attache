import SwiftUI

@main
struct AttacheApp: App {
    @State private var app = AppModel()
    @State private var settings = AppSettings.load()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(settings)
                .preferredColorScheme(.dark)
                .task { bootstrap() }
        }
    }

    @MainActor
    private func bootstrap() {
        guard app.engine == nil else { return }
        if let pairing = settings.pairing {
            let engine = BridgeEngine(pairing: pairing)
            app.engine = engine
            app.onboarding = .done
            engine.start(app: app)
        } else if settings.completedOnboardingWithDemo {
            startDemo()
        }
        NotificationManager.shared.configure(app: app)
    }

    @MainActor
    private func startDemo() {
        let engine = DemoEngine()
        app.engine = engine
        app.onboarding = .done
        engine.start(app: app)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        ZStack {
            Theme.bg.ignoresSafeArea()
            switch app.onboarding {
            case .welcome:
                WelcomeView()
            case .pairing:
                PairingFlowView()
            case .notifications:
                NotifyPermissionView()
            case .done:
                NavigationStack(path: $app.path) {
                    HomeView()
                        .navigationBarHidden(true)
                        .navigationDestination(for: Route.self) { route in
                            destination(for: route)
                                .navigationBarHidden(true)
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .stream: StreamView()
        case .agents: AgentsView()
        case .approvals: ApprovalsView()
        case .plan: PlanView()
        case .diff: DiffView()
        case .resume: ResumeView()
        case .settings: SettingsView()
        case .machines: MachinesView()
        }
    }
}

/// Small persisted app settings (pairing info, onboarding completion).
/// The bearer token itself lives in the Keychain.
@Observable
final class AppSettings {
    var pairing: PairingInfo? {
        didSet { save() }
    }
    var completedOnboardingWithDemo: Bool {
        didSet { save() }
    }
    var notificationsRequested: Bool {
        didSet { save() }
    }

    init(pairing: PairingInfo?, completedOnboardingWithDemo: Bool, notificationsRequested: Bool) {
        self.pairing = pairing
        self.completedOnboardingWithDemo = completedOnboardingWithDemo
        self.notificationsRequested = notificationsRequested
    }

    static func load() -> AppSettings {
        let defaults = UserDefaults.standard
        var pairing: PairingInfo?
        if let host = defaults.string(forKey: "bridge.host"), !host.isEmpty,
           let token = Keychain.read(key: "bridge.token") {
            pairing = PairingInfo(host: host, token: token, machineName: defaults.string(forKey: "bridge.machineName") ?? "machine")
        }
        return AppSettings(
            pairing: pairing,
            completedOnboardingWithDemo: defaults.bool(forKey: "onboarding.demo"),
            notificationsRequested: defaults.bool(forKey: "notifications.requested")
        )
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(pairing?.host ?? "", forKey: "bridge.host")
        defaults.set(pairing?.machineName ?? "", forKey: "bridge.machineName")
        if let token = pairing?.token {
            Keychain.write(key: "bridge.token", value: token)
        } else {
            Keychain.delete(key: "bridge.token")
        }
        defaults.set(completedOnboardingWithDemo, forKey: "onboarding.demo")
        defaults.set(notificationsRequested, forKey: "notifications.requested")
    }
}

struct PairingInfo: Equatable {
    var host: String      // "100.x.y.z:8674"
    var token: String
    var machineName: String
}

enum Keychain {
    static func write(key: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
