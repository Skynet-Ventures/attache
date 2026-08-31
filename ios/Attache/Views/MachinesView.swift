import SwiftUI

struct MachinesView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    /// Set during onboarding so a successful pair continues to notifications.
    var onboardingMode = false
    var onPaired: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            if !onboardingMode {
                header
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PairCard(onboardingMode: onboardingMode, onPaired: onPaired)
                        .padding(.bottom, 12)
                    if !app.pairedMachines.isEmpty {
                        SectionHeader(title: "Paired")
                            .padding(.bottom, 7)
                        pairedCard
                            .padding(.bottom, 10)
                    }
                    WakeTargetsCard()
                        .padding(.bottom, 10)
                    Text("direct over your tailnet · tokens stay on your devices · revoke anytime")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Theme.streamGutter)
                .padding(.top, 14)
                .padding(.bottom, 30)
            }
        }
        .background(Theme.bg)
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackChevron { dismiss() }
            Text("Machines")
                .font(Theme.sans(15, .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(.horizontal, Theme.streamGutter)
        .padding(.bottom, 10)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline), alignment: .bottom)
    }

    private var pairedCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(app.pairedMachines.enumerated()), id: \.element.id) { idx, machine in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        machineDot(machine.state)
                        Text(machine.name)
                            .font(Theme.sans(13, .semibold))
                            .foregroundStyle(isOnline(machine.state) ? Theme.text : Theme.text(0.6))
                        Spacer()
                        if machine.canWake {
                            wakeButton(machine)
                        } else {
                            Text(machine.sessionsLabel)
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    Text(machine.detail)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.text(0.4))
                        .padding(.leading, 15)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
                .contextMenu {
                    Button(role: .destructive) {
                        removeMachine(machine)
                    } label: {
                        Label("Remove machine — revoke token", systemImage: "minus.circle")
                    }
                }
                if idx < app.pairedMachines.count - 1 {
                    Divider().overlay(Theme.hairlineFaint)
                }
            }
        }
        .background(Theme.raisedAlt)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairlineFaint))
    }

    /// Forget a machine: disconnect its client, drop its token from the
    /// Keychain. The user can always re-pair (which replaces the record).
    private func removeMachine(_ machine: PairedMachine) {
        app.engine?.removeMachine(id: machine.id)
        settings.removeMachine(id: machine.id)
    }

    private func isOnline(_ state: PairedMachine.State) -> Bool {
        if case .online = state { return true }
        return false
    }

    private func machineDot(_ state: PairedMachine.State) -> some View {
        let color: Color = switch state {
        case .online: Theme.success
        case .waking: Theme.warning
        case .asleep, .offline: Theme.text(0.25)
        }
        return Circle().fill(color).frame(width: 7, height: 7)
    }

    private func wakeButton(_ machine: PairedMachine) -> some View {
        let (label, color, border): (String, Color, Color) = switch machine.state {
        case .online: ("online", Theme.success, Theme.success.opacity(0.45))
        case .waking: ("waking…", Theme.warning, Theme.warning.opacity(0.45))
        default: ("wake", Theme.accent, Theme.accent.opacity(0.45))
        }
        return Button {
            app.engine?.wakeMachine(id: machine.id)
        } label: {
            Text(label)
                .font(Theme.mono(10, .medium))
                .foregroundStyle(color)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(border))
        }
        .buttonStyle(PressableStyle(scale: 0.92))
    }
}

// MARK: - Wake-on-LAN targets

private struct WakeTarget: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var mac: String
}

/// The bridge broadcasts WOL magic packets on its LAN; targets are stored
/// per-device here. Useful for waking a desktop the bridge machine can see.
private struct WakeTargetsCard: View {
    @Environment(AppModel.self) private var app
    @State private var targets: [WakeTarget] = WakeTargetsCard.load()
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newMac = ""
    @State private var status: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader(title: "Wake-on-LAN")
                Spacer()
                Button {
                    showAdd = true
                } label: {
                    Text("+ add")
                        .font(Theme.mono(10, .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 7)
            if targets.isEmpty {
                Text("add a machine's MAC — the bridge broadcasts the magic packet on its network")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.raisedAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairlineFaint))
            } else {
                VStack(spacing: 0) {
                    ForEach(targets) { target in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(target.name)
                                    .font(Theme.sans(12.5, .medium))
                                    .foregroundStyle(Theme.text)
                                Text(target.mac)
                                    .font(Theme.mono(9.5))
                                    .foregroundStyle(Theme.text(0.4))
                            }
                            Spacer()
                            if let s = status[target.id] {
                                Text(s)
                                    .font(Theme.mono(9.5))
                                    .foregroundStyle(s == "sent" ? Theme.success : Theme.danger)
                            }
                            Button {
                                Task {
                                    let ok = await app.engine?.wake(mac: target.mac) ?? false
                                    status[target.id] = ok ? "sent" : "failed"
                                }
                            } label: {
                                Text("wake")
                                    .font(Theme.mono(10, .medium))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.accent.opacity(0.45)))
                            }
                            .buttonStyle(PressableStyle(scale: 0.92))
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .contextMenu {
                            Button(role: .destructive) {
                                targets.removeAll { $0.id == target.id }
                                WakeTargetsCard.save(targets)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        if target.id != targets.last?.id {
                            Divider().overlay(Theme.hairlineFaint)
                        }
                    }
                }
                .background(Theme.raisedAlt)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairlineFaint))
            }
        }
        .alert("Add wake target", isPresented: $showAdd) {
            TextField("name (e.g. desktop)", text: $newName)
            TextField("MAC — aa:bb:cc:dd:ee:ff", text: $newMac)
            Button("Add") {
                let mac = newMac.trimmingCharacters(in: .whitespaces)
                let name = newName.trimmingCharacters(in: .whitespaces)
                newName = ""; newMac = ""
                guard !mac.isEmpty else { return }
                targets.append(WakeTarget(name: name.isEmpty ? "machine" : name, mac: mac))
                WakeTargetsCard.save(targets)
            }
            Button("Cancel", role: .cancel) { newName = ""; newMac = "" }
        }
    }

    private static func load() -> [WakeTarget] {
        guard let data = UserDefaults.standard.data(forKey: "wake.targets"),
              let targets = try? JSONDecoder().decode([WakeTarget].self, from: data) else { return [] }
        return targets
    }

    private static func save(_ targets: [WakeTarget]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(targets), forKey: "wake.targets")
    }
}

// MARK: - Pairing card (shared with onboarding)

struct PairCard: View {
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings

    var onboardingMode = false
    var onPaired: (() -> Void)? = nil

    @State private var address = ""
    @State private var code = ""
    @State private var copied = false
    @State private var pairing = false
    @State private var pairedName: String?
    @State private var errorText: String?
    @FocusState private var codeFocused: Bool

    private let command = "bunx attache-bridge serve"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(onboardingMode ? "Pair a machine" : "Add a machine")
                .font(Theme.sans(14, .semibold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 4)
            Text(onboardingMode
                ? "On the machine running omp:"
                : "Pair another machine, or re-pair one whose token was revoked:")
                .font(Theme.sans(11.5))
                .foregroundStyle(Theme.text(0.5))
                .padding(.bottom, 12)
            HStack(spacing: 8) {
                (Text("$ ").foregroundStyle(Theme.text(0.4)) + Text(command).foregroundStyle(Theme.text))
                    .font(Theme.mono(12))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                Button {
                    UIPasteboard.general.string = command
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        copied = false
                    }
                } label: {
                    Text(copied ? "copied" : "copy")
                        .font(Theme.mono(9.5, .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.accent.opacity(0.45)))
                }
                .buttonStyle(PressableStyle(scale: 0.92))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.codeBlock)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairlineStrong))
            .padding(.bottom, 14)

            Text("ENTER THE ADDRESS AND CODE IT PRINTS")
                .font(Theme.mono(10))
                .tracking(0.8)
                .foregroundStyle(Theme.text(0.4))
                .padding(.bottom, 8)

            TextField("100.x.y.z:8674", text: $address)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.text)
                .tint(Theme.accent)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Theme.codeBlock)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairlineStrong))
                .padding(.bottom, 8)

            codeCells
                .padding(.bottom, 12)

            if let error = errorText {
                Text(error)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.danger)
                    .padding(.bottom, 10)
            }

            if let name = pairedName {
                HStack(spacing: 8) {
                    Text("✓ \(name) paired · token stored in Keychain")
                        .font(Theme.sans(12.5, .medium))
                        .foregroundStyle(Theme.success)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Theme.success.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.success.opacity(0.4)))
                if onboardingMode {
                    Button {
                        onPaired?()
                    } label: {
                        Text("Continue — notifications")
                            .font(Theme.sans(13, .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(PressableStyle(scale: 0.97))
                    .padding(.top, 10)
                }
            } else {
                Button(action: pair) {
                    HStack(spacing: 8) {
                        if pairing { ProgressView().controlSize(.small).tint(.black) }
                        Text(pairing ? "Pairing…" : "Pair")
                            .font(Theme.sans(12.5, .semibold))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(canPair ? Theme.accent : Theme.accent.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(PressableStyle(scale: 0.97))
                .disabled(!canPair || pairing)
            }
        }
        .padding(16)
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
    }

    private var canPair: Bool {
        !address.isEmpty && code.count == 8
    }

    private var codeCells: some View {
        ZStack {
            TextField("", text: $code)
                .focused($codeFocused)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .foregroundStyle(.clear)
                .tint(.clear)
                .onChange(of: code) {
                    code = String(
                        code.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8)
                    )
                }
            HStack(spacing: 7) {
                ForEach(0..<4, id: \.self) { i in
                    let chunk = codeChunk(i)
                    Text(chunk.isEmpty ? (isActiveCell(i) ? "··" : "") : chunk)
                        .font(Theme.mono(18, .semibold))
                        .foregroundStyle(chunk.isEmpty ? Theme.text(0.25) : Theme.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(Theme.codeBlock)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(chunk.isEmpty ? Color.white.opacity(0.12) : Theme.accent.opacity(0.5))
                        )
                }
            }
            .allowsHitTesting(false)
        }
        .frame(height: 46)
        .contentShape(Rectangle())
        .onTapGesture { codeFocused = true }
    }

    private func codeChunk(_ i: Int) -> String {
        let start = i * 2
        guard code.count > start else { return "" }
        let end = min(code.count, start + 2)
        let s = code.index(code.startIndex, offsetBy: start)
        let e = code.index(code.startIndex, offsetBy: end)
        return String(code[s..<e])
    }

    private func isActiveCell(_ i: Int) -> Bool {
        code.count / 2 == i
    }

    private func pair() {
        errorText = nil
        pairing = true
        let host = address.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let result = try await BridgeClient.pair(host: host, code: code, deviceName: UIDevice.current.name)
                let record = PairedMachineRecord(
                    id: UUID().uuidString,
                    name: result.machineName,
                    host: host,
                    pushKey: result.pushKey
                )
                settings.addMachine(record, token: result.token)
                pairedName = result.machineName
                pairing = false
                if !onboardingMode {
                    // Wire the new machine into the live engine without
                    // dropping any already-paired machines (contract I). A
                    // demo/no engine gets replaced by a real one.
                    if app.engine is DemoEngine || app.engine == nil {
                        let engine = BridgeEngine(machines: settings.pairedMachines)
                        app.engine = engine
                        engine.start(app: app)
                    } else {
                        app.engine?.connectMachine(record)
                    }
                }
            } catch {
                pairing = false
                errorText = (error as? BridgeError)?.message ?? "couldn't reach the bridge — check the address"
            }
        }
    }
}
