import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("å")
                .font(Theme.mono(32, .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 72, height: 72)
                .background(Theme.chip)
                .clipShape(RoundedRectangle(cornerRadius: 19))
                .overlay(RoundedRectangle(cornerRadius: 19).stroke(Theme.accent.opacity(0.5)))
                .padding(.bottom, 18)
            Text("Attaché")
                .font(Theme.sans(26, .bold))
                .foregroundStyle(Theme.text)
                .kerning(-0.5)
                .padding(.bottom, 8)
            Text("A native remote for omp.\nFull visibility, zero terminal.")
                .font(Theme.sans(13.5))
                .foregroundStyle(Theme.text(0.6))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.bottom, 26)
            VStack(alignment: .leading, spacing: 10) {
                valueProp("01", "Answer approvals from the lock screen")
                valueProp("02", "Watch advisor + subagents live, steer mid-flight")
                valueProp("03", "Every session, branch and plan in your pocket")
            }
            .padding(.bottom, 30)
            Button {
                app.onboarding = .pairing
            } label: {
                Text("Pair your first machine")
                    .font(Theme.sans(14, .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(PressableStyle(scale: 0.98))
            .padding(.bottom, 10)
            Button {
                settings.completedOnboardingWithDemo = true
                let engine = DemoEngine()
                app.engine = engine
                app.onboarding = .done
                engine.start(app: app)
            } label: {
                Text("Explore with demo data")
                    .font(Theme.sans(12, .medium))
                    .foregroundStyle(Theme.text(0.5))
                    .padding(6)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("direct over your tailnet · your code never leaves your machines")
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.text(0.3))
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 30)
    }

    private func valueProp(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(n)
                .font(Theme.mono(10, .semibold))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.text(0.8))
        }
    }
}

struct PairingFlowView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BackChevron { app.onboarding = .welcome }
                Text("Pair a machine")
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
            }
            .padding(.horizontal, Theme.streamGutter)
            .padding(.bottom, 10)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline), alignment: .bottom)
            ScrollView {
                PairCard(onboardingMode: true) {
                    app.onboarding = .notifications
                }
                .padding(.horizontal, Theme.streamGutter)
                .padding(.top, 14)
            }
        }
    }
}

struct NotifyPermissionView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle()
                    .stroke(Theme.warning.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 64, height: 64)
                BlinkDot(color: Theme.warning, size: 10)
            }
            .padding(.bottom, 18)
            Text("Never miss an approval")
                .font(Theme.sans(22, .bold))
                .foregroundStyle(Theme.text)
                .kerning(-0.4)
                .padding(.bottom, 8)
            Text("Approvals, goal completions and advisor interrupts land on your lock screen with Allow / Deny right there. Per-session mute any time.")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.text(0.6))
                .multilineTextAlignment(.center)
                .lineSpacing(3.5)
                .padding(.bottom, 28)
            Button {
                Task {
                    await NotificationManager.shared.requestPermission()
                    // A machine was just paired to reach this step: start the
                    // APNs handshake so the bridge can push while suspended.
                    UIApplication.shared.registerForRemoteNotifications()
                    finish()
                }
            } label: {
                Text("Enable notifications")
                    .font(Theme.sans(14, .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(PressableStyle(scale: 0.98))
            .padding(.bottom, 10)
            Button {
                finish()
            } label: {
                Text("Later")
                    .font(Theme.sans(12, .medium))
                    .foregroundStyle(Theme.text(0.5))
                    .padding(6)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 30)
    }

    private func finish() {
        settings.notificationsRequested = true
        app.onboarding = .done
        if app.engine == nil, !settings.pairedMachines.isEmpty {
            let engine = BridgeEngine(machines: settings.pairedMachines)
            app.engine = engine
            engine.start(app: app)
        }
    }
}
