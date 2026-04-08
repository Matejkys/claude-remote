import SwiftUI

// Compact row for a single tmux session in the session list.
// Shows project name, session state with color indicator, and quick actions.
struct SessionRowView: View {
    let session: AppState.TmuxSession
    var onCopyAttach: () -> Void
    var onKill: () -> Void

    @State private var showKillConfirmation = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            stateIndicator
            sessionInfo
            Spacer()
            actionButtons
        }
        .padding(.vertical, 4)
        .alert("Kill Session", isPresented: $showKillConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Kill", role: .destructive) { onKill() }
        } message: {
            Text("Kill session '\(session.displayName)'? This will terminate Claude Code running in it.")
        }
    }

    // MARK: - State Indicator

    private var stateIndicator: some View {
        Circle()
            .fill(stateColor)
            .frame(width: 8, height: 8)
    }

    private var stateColor: Color {
        switch session.state {
        case .active:
            return .blue
        case .waitingForInput:
            return .orange
        case .idle:
            return .gray
        case .unknown:
            return .gray.opacity(0.5)
        }
    }

    // MARK: - Session Info

    private var sessionInfo: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(session.displayName)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
                .lineLimit(1)

            HStack(spacing: 4) {
                Text(session.state.displayName)
                    .foregroundStyle(stateColor)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(session.createdFormatted)
                    .foregroundStyle(.secondary)
                if session.projectName != nil {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(session.name)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 4) {
            Button {
                onCopyAttach()
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help("Copy attach command")

            Button {
                showKillConfirmation = true
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.red.opacity(0.7))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help("Kill session")
        }
    }
}
