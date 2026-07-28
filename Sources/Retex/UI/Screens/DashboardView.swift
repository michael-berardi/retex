import SwiftUI
import RetexCore

struct DashboardView: View {
    @EnvironmentObject private var workspace: WorkspaceModel

    private let metricColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 280), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ScreenHeader(
                    workspace.selectedVault?.name ?? "Workspace",
                    description: "A local operating surface for your client work, notes, and agents."
                ) {
                    Button {
                        workspace.reload()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                commandSurface

                LazyVGrid(columns: metricColumns, spacing: 12) {
                    MetricCard(
                        label: "Pipeline value",
                        value: workspace.pipelineValue.formatted(.currency(code: "USD").precision(.fractionLength(0))),
                        detail: "Open + won",
                        symbol: "chart.line.uptrend.xyaxis"
                    )
                    MetricCard(
                        label: "Active relationships",
                        value: workspace.contacts.count.formatted(),
                        detail: "Contacts",
                        symbol: "person.2"
                    )
                    MetricCard(
                        label: "Agent processes",
                        value: workspace.agentRuns.count.formatted(),
                        detail: "\(workspace.activeAgentCount) active",
                        symbol: "waveform.path.ecg"
                    )
                    MetricCard(
                        label: "Markdown records",
                        value: workspace.notes.count.formatted(),
                        detail: "Portable",
                        symbol: "doc.plaintext"
                    )
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        recentNotes
                        liveAgents
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        liveAgents
                        recentNotes
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1240, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollContentBackground(.hidden)
    }

    private var commandSurface: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .foregroundStyle(Color.retexAccent)
                TextField("Search files and records", text: $workspace.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onSubmit {
                        workspace.selectedSection = .notes
                    }
                Text("⌘ K")
                    .metadataStyle()
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Color.retexRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.retexBorder, lineWidth: 1)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    quickAction("Open pipeline", symbol: "rectangle.split.3x1", section: .board)
                    quickAction("Review agent runs", symbol: "waveform.path.ecg", section: .agents)
                    quickAction("Browse notes", symbol: "doc.text", section: .notes)
                }
                VStack(alignment: .leading, spacing: 10) {
                    quickAction("Open pipeline", symbol: "rectangle.split.3x1", section: .board)
                    quickAction("Review agent runs", symbol: "waveform.path.ecg", section: .agents)
                    quickAction("Browse notes", symbol: "doc.text", section: .notes)
                }
            }
        }
        .retexPanel()
    }

    private var recentNotes: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recently changed")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.retexText)
                .padding(.bottom, 14)

            ForEach(Array(workspace.notes.prefix(6).enumerated()), id: \.element.id) { index, note in
                Button {
                    workspace.select(note)
                } label: {
                    NoteRow(note: note)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                if index < min(workspace.notes.count, 6) - 1 {
                    Divider().overlay(Color.retexBorder)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .retexPanel()
    }

    private var liveAgents: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Agent activity")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.retexText)

            if workspace.agentRuns.isEmpty {
                Text("Agent runs appear as Markdown records in this vault.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.retexMuted)
            } else {
                ForEach(workspace.agentRuns.prefix(4)) { run in
                    Button {
                        workspace.select(run, section: .agents)
                    } label: {
                        HStack(spacing: 10) {
                            StatusDot(status: run.status)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(run.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.retexText)
                                    .lineLimit(1)
                                Text(run.model ?? "Local process")
                                    .metadataStyle()
                            }
                            Spacer()
                            Text(run.status.uppercased())
                                .metadataStyle()
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 320, alignment: .leading)
        .retexPanel()
    }

    private func quickAction(_ title: String, symbol: String, section: WorkspaceSection) -> some View {
        Button {
            workspace.selectedSection = section
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.retexMuted)
    }
}
