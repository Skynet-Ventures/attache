import SwiftUI

struct ResumeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var allProjects = false
    @State private var results: [SessionSummary] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    scopeChip("\(app.machine.name) — this folder", active: !allProjects) { allProjects = false }
                    scopeChip("all projects ⇥", active: allProjects) { allProjects = true }
                    Spacer()
                }
                .padding(.bottom, 10)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textFaint)
                    TextField("Title, session id, or any prompt text…", text: $query)
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.text)
                        .tint(Theme.accent)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Theme.searchField)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairlineFaint))
                .padding(.bottom, 12)
            }
            .padding(.horizontal, Theme.streamGutter)
            .padding(.top, 12)
            ScrollView {
                VStack(spacing: 0) {
                    let rows = displayedRows
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, session in
                            row(session)
                            if idx < rows.count - 1 {
                                Divider().overlay(Theme.hairlineFaint)
                            }
                        }
                    }
                    .background(Theme.raisedAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairlineFaint))
                    Text("search reaches prompts deep in long sessions · ⇥ switches scope")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.textFaint)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Theme.streamGutter)
            }
        }
        .background(Theme.bg)
        .onChange(of: query) { runSearch() }
        .task { runSearch() }
    }

    private var displayedRows: [SessionSummary] {
        if !query.isEmpty { return results }
        let all = app.projects.flatMap(\.sessions)
        if allProjects { return all }
        // "This folder" scope: the active session's project, or the first group.
        let currentCwd = app.projects.first { g in g.sessions.contains { $0.id == app.sessionId } }?.cwd
            ?? app.projects.first?.cwd
        return all.filter { $0.cwd == currentCwd }
    }

    private func runSearch() {
        searchTask?.cancel()
        let q = query
        guard !q.isEmpty else { results = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let engine = app.engine else { return }
            let found = await engine.searchSessions(q)
            if !Task.isCancelled { results = found }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackChevron { dismiss() }
            Text("Resume")
                .font(Theme.sans(15, .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            Text("omp -r")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, Theme.streamGutter)
        .padding(.bottom, 10)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline), alignment: .bottom)
    }

    private func scopeChip(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(Theme.mono(10.5, .medium))
                .foregroundStyle(active ? Theme.accent : Theme.text(0.6))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(active ? Theme.accent.opacity(0.14) : Theme.chip)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Theme.accentBorder : Theme.hairlineStrong))
        }
        .buttonStyle(.plain)
    }

    private func row(_ session: SessionSummary) -> some View {
        Button {
            app.engine?.openSession(session)
        } label: {
            HStack(spacing: 10) {
                Circle().fill(dotColor(session)).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(subtitle(session))
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.text(0.4))
                        .lineLimit(1)
                }
                Spacer()
                Text(session.shortId)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.text(0.3))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dotColor(_ session: SessionSummary) -> Color {
        switch session.status {
        case .running: Theme.accent
        case .waiting: Theme.warning
        case .done: Theme.success
        case .idle: Theme.text(0.25)
        }
    }

    private func subtitle(_ session: SessionSummary) -> String {
        let state: String = switch session.status {
        case .running: "live · turn \(app.turnNo)"
        case .waiting: "plan"
        case .done: "merged · \(session.ageLabel)"
        case .idle: "idle · \(session.ageLabel)"
        }
        return "\(session.project) · \(state)"
    }
}
