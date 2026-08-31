import SwiftUI
import WidgetKit

/// Receives the APNs device token once the user has granted notification
/// permission. Pure plumbing: the token is handed to PushRegistrar, which
/// BridgeEngine forwards to every paired bridge as an `apns` push target.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            PushRegistrar.shared.setDeviceToken(token)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // APNs unavailable (simulator, no entitlement): the WebSocket path
        // and webhooks still cover every in-app surface.
    }
}

@main
struct AttacheApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Freshen home-screen widgets whenever the app comes back —
                // timeline reloads are gated on actual value changes inside.
                app.publishWidgetSnapshot()
                WidgetCenter.shared.reloadAllTimelines()
                settings.refreshPushContextMirror()
            }
        }
    }

    @MainActor
    private func bootstrap() {
        guard app.engine == nil else { return }
        if !settings.pairedMachines.isEmpty {
            let engine = BridgeEngine(machines: settings.pairedMachines)
            app.engine = engine
            app.onboarding = .done
            engine.start(app: app)
            settings.refreshPushContextMirror()
            // Remote push needs a paired machine to have somewhere to go.
            UIApplication.shared.registerForRemoteNotifications()
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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
                if horizontalSizeClass == .regular {
                    // iPad: sessions sidebar | stream detail. The detail column
                    // reuses the iPhone navigation stack so every existing
                    // flow (and the sessions the sidebar opens) behaves
                    // identically — only the entry point differs.
                    NavigationSplitView {
                        SessionsSidebar()
                            .navigationSplitViewColumnWidth(min: 250, ideal: 310, max: 380)
                    } detail: {
                        NavigationStack(path: $app.path) {
                            HomeView()
                                .navigationBarHidden(true)
                                .navigationDestination(for: Route.self) { route in
                                    destination(for: route)
                                        .navigationBarHidden(true)
                                        .edgeSwipeBack()
                                }
                        }
                    }
                } else {
                    NavigationStack(path: $app.path) {
                        HomeView()
                            .navigationBarHidden(true)
                            .navigationDestination(for: Route.self) { route in
                                destination(for: route)
                                    .navigationBarHidden(true)
                                    .edgeSwipeBack()
                            }
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
        case .rules: RulesView()
        case .costs: CostDashboardView()
        }
    }
}

/// Small persisted app settings (paired machines, onboarding completion).
/// Bearer tokens live in the Keychain under one key per machine
/// ("bridge.token.<machineId>"); pair codes and push keys are non-secret and
/// stay here.
@Observable
final class AppSettings {
    /// Every paired machine (contract I). Single-machine installs keep exactly
    /// one entry and see no behavior change.
    var pairedMachines: [PairedMachineRecord] {
        didSet { save() }
    }
    var completedOnboardingWithDemo: Bool {
        didSet { save() }
    }
    var notificationsRequested: Bool {
        didSet { save() }
    }

    /// Back-compat read accessor: the primary machine as the old single
    /// pairing shape.
    var pairing: PairingInfo? {
        guard let m = pairedMachines.first else { return nil }
        return PairingInfo(
            id: m.id,
            host: m.host,
            token: Keychain.read(key: Self.tokenKey(m.id)) ?? "",
            machineName: m.name,
            pushKey: m.pushKey
        )
    }

    init(pairedMachines: [PairedMachineRecord], completedOnboardingWithDemo: Bool, notificationsRequested: Bool) {
        self.pairedMachines = pairedMachines
        self.completedOnboardingWithDemo = completedOnboardingWithDemo
        self.notificationsRequested = notificationsRequested
    }

    static func load() -> AppSettings {
        load(defaults: .standard)
    }

    /// Loads paired machines, migrating the legacy single-pairing keys
    /// ("bridge.host" / "bridge.token" / "bridge.machineName") into the new
    /// per-machine store on first launch. Injectable storage keeps the
    /// migration unit-testable.
    static func load(defaults: UserDefaults) -> AppSettings {
        var machines: [PairedMachineRecord] = []
        if let data = defaults.data(forKey: "bridge.machines"),
           let decoded = try? JSONDecoder().decode([PairedMachineRecord].self, from: data) {
            machines = decoded
        }
        if machines.isEmpty,
           let host = defaults.string(forKey: "bridge.host"), !host.isEmpty {
            let id = UUID().uuidString
            let name = defaults.string(forKey: "bridge.machineName") ?? "machine"
            let token = Keychain.read(key: "bridge.token") ?? ""
            let pushKey = defaults.string(forKey: "bridge.pushKey") ?? ""
            machines = [PairedMachineRecord(id: id, name: name, host: host, pushKey: pushKey)]
            if !token.isEmpty { Keychain.write(key: tokenKey(id), value: token) }
            // The migrated store is now authoritative; drop the legacy keys.
            defaults.removeObject(forKey: "bridge.host")
            defaults.removeObject(forKey: "bridge.machineName")
            defaults.removeObject(forKey: "bridge.token")
            defaults.removeObject(forKey: "bridge.pushKey")
            defaults.set(try? JSONEncoder().encode(machines), forKey: "bridge.machines")
        }
        return AppSettings(
            pairedMachines: machines,
            completedOnboardingWithDemo: defaults.bool(forKey: "onboarding.demo"),
            notificationsRequested: defaults.bool(forKey: "notifications.requested")
        )
    }

    /// Persist a freshly paired machine (token goes to its Keychain slot).
    /// Re-pairing an existing machine replaces the old record.
    func addMachine(_ record: PairedMachineRecord, token: String) {
        Keychain.write(key: Self.tokenKey(record.id), value: token)
        pairedMachines.removeAll { $0.id == record.id }
        pairedMachines.append(record)
        // The push key and host must be available to the notification
        // service extension immediately — a background push could arrive
        // before the next foreground mirror.
        refreshPushContextMirror()
    }

    /// Forget a machine and delete its token from the Keychain.
    func removeMachine(id: String) {
        Keychain.delete(key: Self.tokenKey(id))
        pairedMachines.removeAll { $0.id == id }
    }

    static func tokenKey(_ id: String) -> String { "bridge.token.\(id)" }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(pairedMachines), forKey: "bridge.machines")
        defaults.set(completedOnboardingWithDemo, forKey: "onboarding.demo")
        defaults.set(notificationsRequested, forKey: "notifications.requested")
    }
}

struct PairingInfo: Equatable {
    var id: String
    var host: String      // "100.x.y.z:8674"
    var token: String
    var machineName: String
    /// Base64 AES-256-GCM key exchanged at pair time for APNs (contract H).
    /// Empty for pairings made before this field existed.
    var pushKey: String
}
