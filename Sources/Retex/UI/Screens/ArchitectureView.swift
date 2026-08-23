import SwiftUI

struct ArchitectureView: View {
    private let decisions = [
        ArchitectureDecision(
            title: "SwiftUI shell",
            symbol: "swift",
            body: "Swift gives macOS and iOS native controls, accessibility, window behavior, file dialogs, and platform integration from one UI model. Go would need a UI layer. Rust adds a bridge before the product needs one."
        ),
        ArchitectureDecision(
            title: "Markdown is authoritative",
            symbol: "doc.plaintext",
            body: "Retex reads ordinary folders. YAML properties drive views. Wiki links, tags, attachments, and note bodies stay usable in Obsidian and any text editor."
        ),
        ArchitectureDecision(
            title: "Indexes are disposable",
            symbol: "externaldrive.badge.checkmark",
            body: "The first prototype scans files directly. A later SQLite FTS index can make large vaults instant, but deleting that cache must never delete knowledge."
        ),
        ArchitectureDecision(
            title: "Small integration surface",
            symbol: "point.3.connected.trianglepath.dotted",
            body: "Files, a local command-line tool, event hooks, and an MCP server form the extension boundary. Integrations should call stable verbs instead of changing the interface."
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ScreenHeader(
                    "Architecture",
                    description: "Native where the platform matters. Plain files everywhere else."
                )

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                    ForEach(decisions) { decision in
                        decisionCard(decision)
                    }
                }

                fileContract
                integrationPath
                privacyBoundary
            }
            .padding(28)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func decisionCard(_ decision: ArchitectureDecision) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: decision.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.retexAccent)
            Text(decision.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.retexText)
            Text(decision.body)
                .font(.system(size: 13))
                .foregroundStyle(Color.retexMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .retexPanel()
    }

    private var fileContract: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Obsidian-compatible record")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.retexText)
            Text("Retex reserves a small set of optional properties. Everything else passes through unchanged.")
                .font(.system(size: 13))
                .foregroundStyle(Color.retexMuted)

            Text(
                """
                ---
                type: deal
                status: Proposal
                owner: Retex Team
                value: $11,500
                next_action: Send revised scope
                tags: [crm, priority]
                ---

                # Acme website rebuild

                Linked contact: [[Jamie Doe]]
                """
            )
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color.retexText)
            .textSelection(.enabled)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.retexCanvas)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.retexBorder, lineWidth: 1)
            }
        }
        .retexPanel()
    }

    private var integrationPath: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Integration path")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.retexText)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    integrationStep("01", "Files", "Read and write portable records")
                    connector
                    integrationStep("02", "CLI", "Script stable local commands")
                    connector
                    integrationStep("03", "MCP", "Give agents scoped tools")
                    connector
                    integrationStep("04", "Sync", "Optional end-to-end encrypted transport")
                }
                .frame(minWidth: 700)
            }
        }
        .retexPanel()
    }

    private func integrationStep(_ number: String, _ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(number).metadataStyle()
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.retexText)
            Text(body)
                .font(.system(size: 11))
                .foregroundStyle(Color.retexMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connector: some View {
        Rectangle()
            .fill(Color.retexBorder)
            .frame(width: 24, height: 1)
            .padding(.top, 24)
    }

    private var privacyBoundary: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 18))
                .foregroundStyle(Color.retexSuccess)
            VStack(alignment: .leading, spacing: 5) {
                Text("Default privacy boundary")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.retexText)
                Text("No account, analytics, remote database, or background upload. Networked features must be explicit, scoped, inspectable, and replaceable.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.retexMuted)
            }
        }
        .retexPanel()
    }
}

private struct ArchitectureDecision: Identifiable {
    let title: String
    let symbol: String
    let body: String
    var id: String { title }
}
