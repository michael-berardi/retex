import SwiftUI
import RetexCore

struct ComparisonView: View {
    private let rows = [
        ComparisonRow(
            capability: "Default job",
            retex: "Run a multi-vault CRM and agent knowledge base without assembling a system first.",
            obsidian: "General-purpose personal knowledge management with broad customization.",
            advantage: "Retex removes setup decisions for this specific workflow."
        ),
        ComparisonRow(
            capability: "Source files",
            retex: "Plain Markdown, YAML properties, wiki links, and ordinary folders.",
            obsidian: "Plain Markdown vaults with YAML properties and wiki links.",
            advantage: "Shared format. Existing vaults remain portable in both directions."
        ),
        ComparisonRow(
            capability: "CRM views",
            retex: "Pipeline, contacts, notes, and activity are built into the core product.",
            obsidian: "Bases and plugins can produce database and board workflows after configuration.",
            advantage: "Retex gives every vault the same operating model by default."
        ),
        ComparisonRow(
            capability: "Agent operations",
            retex: "Agent runs are first-class records with status, model, owner, duration, and output.",
            obsidian: "Agent workflows depend on external tools, scripts, CLI use, or community plugins.",
            advantage: "Retex makes machine work visible beside human work."
        ),
        ComparisonRow(
            capability: "Desktop runtime",
            retex: "Native SwiftUI shell for macOS with the same UI model available to iOS.",
            obsidian: "Mature cross-platform Electron desktop client plus native mobile apps.",
            advantage: "Retex targets native Mac behavior and lower architectural overhead. Performance still needs benchmarking."
        ),
        ComparisonRow(
            capability: "Extensibility",
            retex: "Small, versioned local protocols for files, commands, events, and MCP tools.",
            obsidian: "Large TypeScript plugin and theme ecosystem with extensive user choice.",
            advantage: "Retex favors stable contracts over UI-level customization."
        ),
        ComparisonRow(
            capability: "Open source",
            retex: "MIT-licensed application code and documented file contracts.",
            obsidian: "Proprietary core. Help, developer docs, JSON Canvas, Importer, and selected tools are open source.",
            advantage: "Retex can be audited, forked, and self-maintained end to end."
        ),
        ComparisonRow(
            capability: "Maturity",
            retex: "Early native prototype focused on one opinionated workflow.",
            obsidian: "Established product with broad platform support, sync, publishing, plugins, and a large community.",
            advantage: "Obsidian wins today. Retex has a narrower target and a simpler path to coherence."
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ScreenHeader(
                    "Retex and Obsidian",
                    description: "The useful parts stay compatible. The product defaults change."
                )

                thesis

                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        comparisonHeader
                        ForEach(rows) { row in
                            comparisonRow(row)
                            if row.id != rows.last?.id {
                                Divider().overlay(Color.retexBorder)
                            }
                        }
                    }
                    .frame(minWidth: 900)
                    .background(Color.retexSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.retexBorder, lineWidth: 1)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var thesis: some View {
        HStack(alignment: .top, spacing: 18) {
            RetexMark(size: 42)
            VStack(alignment: .leading, spacing: 7) {
                Text("An agent workspace with a fixed center of gravity")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.retexText)
                Text("Retex treats the vault as an operating system for clients, projects, and agents. It keeps Markdown as the durable layer, then ships the views and conventions the workflow needs.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.retexMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .retexPanel()
    }

    private var comparisonHeader: some View {
        HStack(spacing: 0) {
            tableCell("Capability", width: 150, emphasized: true)
            tableCell("Retex", emphasized: true)
            tableCell("Obsidian", emphasized: true)
            tableCell("Practical difference", emphasized: true)
        }
        .background(Color.retexRaised)
    }

    private func comparisonRow(_ row: ComparisonRow) -> some View {
        HStack(alignment: .top, spacing: 0) {
            tableCell(row.capability, width: 150, emphasized: true)
            tableCell(row.retex)
            tableCell(row.obsidian)
            tableCell(row.advantage, tint: .retexAccent)
        }
    }

    @ViewBuilder
    private func tableCell(
        _ text: String,
        width: CGFloat? = nil,
        emphasized: Bool = false,
        tint: Color = .retexMuted
    ) -> some View {
        let cell = Text(text)
            .font(.system(size: 12, weight: emphasized ? .semibold : .regular))
            .foregroundStyle(emphasized ? Color.retexText : tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)

        if let width {
            cell.frame(width: width, alignment: .topLeading)
        } else {
            cell.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
