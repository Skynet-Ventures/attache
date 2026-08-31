import SwiftUI

struct DiffView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showRequestInput = false
    @State private var requestText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(app.diff?.lines ?? []) { line in
                        DiffLineView(line: line, fontSize: 11)
                            .padding(.horizontal, 3)
                    }
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.composer)
            footer
        }
        .background(Theme.bg)
        .alert("Request changes", isPresented: $showRequestInput) {
            TextField("What should change?", text: $requestText)
            Button("Send") {
                app.engine?.diffVerdict(approved: false, note: requestText)
                requestText = ""
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BackChevron { dismiss() }
            VStack(alignment: .leading, spacing: 1) {
                Text(app.diff?.fileName ?? "diff")
                    .font(Theme.mono(15, .semibold))
                    .foregroundStyle(Theme.text)
                Text(app.diff?.directory ?? "")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            Text("+\(app.diff?.addCount ?? 0)")
                .font(Theme.mono(10, .medium))
                .foregroundStyle(Theme.success)
            Text("−\(app.diff?.delCount ?? 0)")
                .font(Theme.mono(10, .medium))
                .foregroundStyle(Theme.danger)
            if let hash = app.diff?.hashline, !hash.isEmpty {
                Text(hash)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.text(0.3))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.12)))
            }
        }
        .padding(.horizontal, Theme.streamGutter)
        .padding(.bottom, 10)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline), alignment: .bottom)
    }

    private var footer: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Text(app.diff?.footer ?? "")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.success)
                Spacer()
                Text("hash re-anchors if the file moved")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.text(0.4))
            }
            HStack(spacing: 8) {
                Button {
                    showRequestInput = true
                } label: {
                    Text("Request changes")
                        .font(Theme.sans(12, .medium))
                        .foregroundStyle(Theme.text(0.85))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.15)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    app.engine?.diffVerdict(approved: true, note: nil)
                    dismiss()
                } label: {
                    Text("Looks good")
                        .font(Theme.sans(12, .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(PressableStyle(scale: 0.97))
            }
        }
        .padding(.horizontal, Theme.streamGutter)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(Theme.composer)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.hairline), alignment: .top)
    }
}
