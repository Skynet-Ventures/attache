import SwiftUI

/// iPad split-view sidebar (regular horizontal size class only): sessions
/// grouped by project, one row per machine. Selecting a session opens it in
/// the detail column through the standard engine flow — no separate routing
/// exists here, the sidebar is purely an entry point.
struct SessionsSidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Section {
                machineHeader
            }
            ForEach(app.projects) { project in
                Section(project.name) {
                    ForEach(project.sessions) { session in
                        SidebarSessionRow(session: session, isOpen: session.id == app.sessionId) {
                            open(session)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationTitle(app.machine.link == .demo ? "Demo" : "Sessions")
        .safeAreaInset(edge: .bottom) {
            if app.offline {
                Text("bridge unreachable — retrying")
                    .font(Theme.mono(9, .medium))
                    .foregroundStyle(Theme.diffDelText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color(hex: 0x3C0E0A).opacity(0.88))
            }
        }
    }

    private var machineHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(machineDotColor)
                .frame(width: 7, height: 7)
            Text(app.machine.name)
                .font(Theme.sans(12.5, .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            Text("å")
                .font(Theme.mono(12, .bold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.vertical, 2)
    }

    private var machineDotColor: Color {
        switch app.machine.link {
        case .online, .demo: Theme.success
        case .connecting: Theme.warning
        case .offline: Theme.danger
        }
    }

    private func open(_ session: SessionSummary) {
        if session.id == app.sessionId {
            // Already attached: surface the stream without a re-attach.
            if !app.path.contains(.stream) {
                app.path.append(.stream)
            }
        } else {
            app.engine?.openSession(session)
        }
    }
}

private struct SidebarSessionRow: View {
    let session: SessionSummary
    let isOpen: Bool
    var action: () -> Void

    private var rowTint: Color {
        switch session.status {
        case .running: Theme.accent
        case .waiting: Theme.warning
        case .done: Theme.success
        case .idle: Theme.text(0.3)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(rowTint).frame(width: 6, height: 6)
                Text(session.title)
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer()
                if isOpen {
                    Text("OPEN")
                        .font(Theme.mono(8.5, .semibold))
                        .foregroundStyle(Theme.accent)
                } else {
                    Text(session.ageLabel)
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
