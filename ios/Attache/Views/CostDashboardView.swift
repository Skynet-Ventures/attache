import Charts
import SwiftUI

/// Settings-rooted cost dashboard (contract E): daily cost bars from
/// `get_cost_summary` plus a per-project breakdown. Demo engine seeds canned
/// data so the screen is explorable without a bridge.
struct CostDashboardView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var rangeDays = 30
    @State private var summary: CostSummaryModel?
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if loading {
                Spacer()
                ProgressView().controlSize(.small).tint(Theme.accent)
                Spacer()
            } else if failed {
                Spacer()
                VStack(spacing: 6) {
                    Text("Couldn't load cost summary")
                        .font(Theme.sans(13, .medium))
                        .foregroundStyle(Theme.text(0.7))
                    Text("check that the bridge is reachable")
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.text(0.4))
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        rangeSelector
                            .padding(.bottom, 12)
                        if let summary, !summary.days.isEmpty {
                            dailyChart(summary)
                                .padding(.bottom, 16)
                        }
                        if let summary, !summary.byProject.isEmpty {
                            Text("PER PROJECT — \(totalSpendLabel(summary))")
                                .font(Theme.mono(9.5, .semibold))
                                .tracking(1)
                                .foregroundStyle(Theme.text(0.4))
                                .padding(.bottom, 6)
                            projectCard(summary)
                        }
                    }
                    .padding(.horizontal, Theme.streamGutter)
                    .padding(.top, 12)
                    .padding(.bottom, 30)
                }
            }
        }
        .background(Theme.bg)
        .task { await reload() }
        .onChange(of: rangeDays) { _ in
            Task { await reload() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackChevron { dismiss() }
            Text("Costs & usage")
                .font(Theme.sans(15, .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            if let summary {
                Text("$\(String(format: "%.2f", summary.byProject.reduce(0) { $0 + $1.costUSD }))")
                    .font(Theme.mono(10.5, .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, Theme.streamGutter)
        .padding(.bottom, 10)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline), alignment: .bottom)
    }

    private var rangeSelector: some View {
        HStack(spacing: 0) {
            ForEach([7, 30, 90], id: \.self) { days in
                Button {
                    rangeDays = days
                } label: {
                    Text("\(days)d")
                        .font(Theme.mono(10, rangeDays == days ? .semibold : .medium))
                        .foregroundStyle(rangeDays == days ? .black : Theme.text(0.45))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(rangeDays == days ? Theme.accent : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.raisedAlt)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairlineStrong))
    }

    private func dailyChart(_ summary: CostSummaryModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DAILY — LAST \(rangeDays) DAYS")
                    .font(Theme.mono(9.5, .semibold))
                    .tracking(1)
                    .foregroundStyle(Theme.text(0.4))
                Spacer()
                Text("\(summary.byProject.map(\.sessions).reduce(0, +)) sessions")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.text(0.3))
            }
            let days = summary.days.sorted { $0.date < $1.date }
            Chart(days) { day in
                BarMark(
                    x: .value("Day", day.date),
                    y: .value("Cost", day.costUSD)
                )
                .foregroundStyle(Theme.accent.gradient)
                .cornerRadius(2)
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic) { _ in
                    AxisGridLine().foregroundStyle(Theme.hairlineFaint)
                    AxisTick().foregroundStyle(Theme.hairline)
                    AxisValueLabel()
                        .font(Theme.mono(8))
                        .foregroundStyle(Theme.text(0.4))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: min(days.count, 7))) { _ in
                    AxisValueLabel()
                        .font(Theme.mono(8))
                        .foregroundStyle(Theme.text(0.35))
                }
            }
            .frame(height: 168)
            .padding(.horizontal, 6)
        }
        .padding(12)
        .background(Theme.raisedAlt)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairlineFaint))
    }

    private func projectCard(_ summary: CostSummaryModel) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(summary.byProject.enumerated()), id: \.element.id) { idx, project in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.cwd)
                            .font(Theme.mono(11, .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text("\(project.sessions) session\(project.sessions == 1 ? "" : "s")")
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.text(0.4))
                    }
                    Spacer()
                    Text("$\(String(format: "%.2f", project.costUSD))")
                        .font(Theme.mono(11.5, .semibold))
                        .foregroundStyle(Theme.text(0.9))
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                if idx < summary.byProject.count - 1 {
                    Divider().overlay(Theme.hairlineFaint)
                }
            }
        }
        .background(Theme.raisedAlt)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairlineFaint))
    }

    private func totalSpendLabel(_ summary: CostSummaryModel) -> String {
        let total = summary.byProject.reduce(0) { $0 + $1.costUSD }
        return String(format: "$%.2f", total)
    }

    private func reload() async {
        loading = true
        failed = false
        summary = await app.engine?.fetchCostSummary(days: rangeDays)
        loading = false
        if summary == nil {
            failed = true
        }
    }
}
