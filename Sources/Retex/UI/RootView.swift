import SwiftUI
import UniformTypeIdentifiers
import RetexCore

struct RootView: View {
    @EnvironmentObject private var workspace: WorkspaceModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 216, ideal: 236, max: 280)
        } detail: {
            Group {
                switch workspace.selectedSection ?? .overview {
                case .overview: DashboardView()
                case .board: BoardView()
                case .notes: NotesView()
                case .agents: AgentActivityView()
                case .compare: ComparisonView()
                case .architecture: ArchitectureView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.retexCanvas)
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $workspace.searchQuery, placement: .toolbar, prompt: "Search this vault")
        .alert(
            "Retex could not complete that action",
            isPresented: Binding(
                get: { workspace.errorMessage != nil },
                set: { if !$0 { workspace.errorMessage = nil } }
            )
        ) {
            Button("Dismiss", role: .cancel) { workspace.errorMessage = nil }
        } message: {
            Text(workspace.errorMessage ?? "Unknown error")
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RetexMark(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Retex")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.retexText)
                    Text("LOCAL WORKSPACE")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Color.retexMuted)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            vaultSelector
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            List(selection: $workspace.selectedSection) {
                Section("Workspace") {
                    navigationRow(.overview)
                    navigationRow(.board)
                    navigationRow(.notes)
                }

                Section("Agents") {
                    navigationRow(.agents)
                }

                Section("System") {
                    navigationRow(.compare)
                    navigationRow(.architecture)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            HStack(spacing: 8) {
                Circle()
                    .fill(Color.retexSuccess)
                    .frame(width: 6, height: 6)
                Text("Local only")
                    .metadataStyle()
                Spacer()
                Text("\(workspace.notes.count) files")
                    .metadataStyle()
            }
            .padding(14)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.retexBorder).frame(height: 1)
            }
        }
        .background(Color.retexSidebar)
        .fileImporter(
            isPresented: $workspace.isAddingVault,
            allowedContentTypes: [.directory]
        ) { result in
            if case .success(let url) = result {
                workspace.addVault(url)
            } else if case .failure(let error) = result {
                workspace.errorMessage = error.localizedDescription
            }
        }
    }

    private var vaultSelector: some View {
        HStack(spacing: 6) {
            Image(systemName: "externaldrive")
                .foregroundStyle(Color.retexMuted)
            Picker("Vault", selection: $workspace.selectedVault) {
                ForEach(workspace.vaults) { vault in
                    Text(vault.name).tag(Optional(vault))
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                workspace.isAddingVault = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.retexMuted)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .help("Add a vault")
            .accessibilityLabel("Add a vault")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 36)
        .background(Color.retexSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.retexBorder, lineWidth: 1)
        }
    }

    private func navigationRow(_ section: WorkspaceSection) -> some View {
        Label(section.label, systemImage: section.symbol)
            .tag(section)
    }
}
