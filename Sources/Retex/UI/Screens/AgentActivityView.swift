import SwiftUI
import RetexCore

struct AgentActivityView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @State private var runFilter = ""

    private var runs: [Note] {
        let query = runFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return workspace.agentRuns }
        return workspace.agentRuns.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.status.localizedCaseInsensitiveContains(query)
                || $0.body.localizedCaseInsensitiveContains(query)
                || ($0.model?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ScreenHeader(
                    "Agent activity",
                    description: "Runs, handoffs, and failures stay visible as ordinary Markdown records."
                ) {
                    MetadataPill(text: "\(workspace.activeAgentCount) ACTIVE", tint: .retexAccent)
                }

                filterBar

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        runList
                        runInspector
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        runList
                        runInspector
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(Color.retexMuted)
            TextField("Filter by task, status, model, or output", text: $runFilter)
                .textFieldStyle(.plain)
            if !runFilter.isEmpty {
                Button("Clear") { runFilter = "" }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.retexMuted)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Color.retexSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.retexBorder, lineWidth: 1)
        }
    }

    private var runList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(runs) { run in
                Button {
                    workspace.selectedNoteID = run.id
                } label: {
                    HStack(spacing: 11) {
                        StatusDot(status: run.status)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(run.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.retexText)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(run.model ?? "Local")
                                if let duration = run.duration {
                                    Text("•")
                                    Text(duration)
                                }
                            }
                            .metadataStyle()
                        }
                        Spacer()
                        Text(run.status.uppercased())
                            .metadataStyle()
                    }
                    .padding(12)
                    .background(
                        workspace.selectedNoteID == run.id
                            ? Color.retexAccent.opacity(0.1)
                            : Color.retexSurface
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.retexBorder, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }

            if runs.isEmpty {
                EmptyState(
                    symbol: "waveform.path.ecg",
                    title: "No matching runs",
                    message: "Clear the filter or add an agent-run Markdown record."
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var runInspector: some View {
        if let run = workspace.selectedNote, run.type == .agentRun {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    StatusDot(status: run.status)
                    Text(run.status.uppercased())
                        .metadataStyle()
                    Spacer()
                    Menu("Set status") {
                        ForEach(["Queued", "Working", "Complete", "Blocked"], id: \.self) { status in
                            Button(status) { workspace.move(run, to: status) }
                        }
                    }
                    .menuStyle(.button)
                    .controlSize(.small)
                }

                Text(run.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.retexText)

                HStack(spacing: 8) {
                    if let model = run.model { MetadataPill(text: model) }
                    if let duration = run.duration { MetadataPill(text: duration) }
                    MetadataPill(text: run.owner)
                }

                Divider().overlay(Color.retexBorder)

                Text(run.body)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.retexMuted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Open Markdown record") {
                    workspace.selectedSection = .notes
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.retexAccent)
            }
            .frame(maxWidth: 360, alignment: .topLeading)
            .retexPanel()
        } else {
            EmptyState(
                symbol: "cursorarrow.click",
                title: "Select a run",
                message: "Inspect its input, output, model, and status."
            )
            .frame(maxWidth: 360)
        }
    }
}
