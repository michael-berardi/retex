import SwiftUI
import RetexCore

struct BoardView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @State private var boardQuery = ""
    @State private var ownerFilter = "All owners"
    @State private var editingDeal: Note?
    @State private var isCreatingDeal = false
    @State private var dealToArchive: Note?

    private let columns = BoardColumn.defaultColumns

    private var owners: [String] {
        ["All owners"] + Array(Set(workspace.deals.map(\.owner))).sorted()
    }

    private var filteredDeals: [Note] {
        workspace.deals.filter { note in
            let ownerMatches = ownerFilter == "All owners" || note.owner == ownerFilter
            let query = boardQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let queryMatches = query.isEmpty
                || note.title.localizedCaseInsensitiveContains(query)
                || note.body.localizedCaseInsensitiveContains(query)
                || note.tags.contains { $0.localizedCaseInsensitiveContains(query) }
                || (note.company?.localizedCaseInsensitiveContains(query) ?? false)
            return ownerMatches && queryMatches
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenHeader(
                "Pipeline",
                description: "Drag cards between lists. Retex writes every status, field, label, and checklist back to Markdown."
            ) {
                Button {
                    isCreatingDeal = true
                } label: {
                    Label("New card", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.retexAccent)
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)

            boardControls
                .padding(.horizontal, 28)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(columns) { column in
                        BoardColumnView(
                            column: column,
                            notes: filteredDeals
                                .filter { column.statuses.contains($0.status) }
                                .sorted { $0.rank < $1.rank },
                            onOpen: { editingDeal = $0 },
                            onArchive: { dealToArchive = $0 }
                        )
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $isCreatingDeal) {
            DealEditorSheet(note: nil)
                .environmentObject(workspace)
        }
        .sheet(item: $editingDeal) { note in
            DealEditorSheet(note: note)
                .environmentObject(workspace)
        }
        .alert(
            "Archive this card?",
            isPresented: Binding(
                get: { dealToArchive != nil },
                set: { if !$0 { dealToArchive = nil } }
            ),
            presenting: dealToArchive
        ) { note in
            Button("Archive", role: .destructive) {
                workspace.archive(note)
                dealToArchive = nil
            }
            Button("Cancel", role: .cancel) { dealToArchive = nil }
        } message: { note in
            Text("\(note.title) will stay on disk with archived: true.")
        }
    }

    private var boardControls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.retexMuted)
                TextField("Filter cards, companies, labels, or content", text: $boardQuery)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: 420)
            .frame(height: 36)
            .background(Color.retexSurface)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.retexBorder, lineWidth: 1)
            }

            Picker("Owner", selection: $ownerFilter) {
                ForEach(owners, id: \.self) { Text($0).tag($0) }
            }
            .controlSize(.small)
            .frame(width: 150)

            Spacer()
            Text("\(filteredDeals.count) cards")
                .metadataStyle()
            Text("•")
                .foregroundStyle(Color.retexMuted)
            Text(workspace.pipelineValue.formatted(.currency(code: "USD").precision(.fractionLength(0))))
                .metadataStyle()
        }
    }
}

private struct BoardColumnView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    let column: BoardColumn
    let notes: [Note]
    let onOpen: (Note) -> Void
    let onArchive: (Note) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusDot(status: column.title)
                Text(column.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.retexText)
                Spacer()
                Text(notes.count.formatted())
                    .metadataStyle()
            }
            .padding(.horizontal, 4)

            VStack(spacing: 8) {
                ForEach(notes) { note in
                    DealCard(
                        note: note,
                        onOpen: { onOpen(note) },
                        onArchive: { onArchive(note) }
                    )
                    .draggable(note.id)
                    .dropDestination(for: String.self) { items, _ in
                        guard let sourceID = items.first,
                              sourceID != note.id,
                              let source = workspace.notes.first(where: { $0.id == sourceID }) else {
                            return false
                        }
                        workspace.move(source, to: column.title, rank: note.rank - 0.5)
                        return true
                    }
                }

                if notes.isEmpty {
                    Text("Drop a card here")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.retexMuted)
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.retexBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        }
                }
            }
            .padding(8)
            .frame(width: 276, alignment: .top)
            .background(isTargeted ? Color.retexAccent.opacity(0.08) : Color.retexSidebar)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isTargeted ? Color.retexAccent.opacity(0.5) : Color.retexBorder, lineWidth: 1)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first,
                      let note = workspace.notes.first(where: { $0.id == id }) else {
                    return false
                }
                workspace.move(note, to: column.title)
                return true
            } isTargeted: { isTargeted = $0 }
        }
    }
}

private struct DealCard: View {
    let note: Note
    let onOpen: () -> Void
    let onArchive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.retexText)
                        .multilineTextAlignment(.leading)
                    if let company = note.company {
                        Text(company)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.retexMuted)
                    }
                }
                Spacer(minLength: 12)
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.retexMuted.opacity(0.75))
                    .frame(width: 18, height: 24)
                    .help("Drag card")
                Menu {
                    Button("Open card", action: onOpen)
                    Divider()
                    Button("Archive", role: .destructive, action: onArchive)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Color.retexMuted)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("Card actions for \(note.title)")
            }

            if !note.tags.isEmpty {
                HStack(spacing: 5) {
                    ForEach(note.tags.prefix(3), id: \.self) { tag in
                        MetadataPill(text: tag, tint: tint(for: tag))
                    }
                }
            }

            if let nextAction = note.nextAction {
                Label(nextAction, systemImage: "arrow.turn.down.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.retexMuted)
                    .lineLimit(2)
            }

            let progress = note.checklistProgress
            if progress.total > 0 {
                HStack(spacing: 7) {
                    Image(systemName: progress.completed == progress.total ? "checkmark.circle.fill" : "checklist")
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                        .tint(Color.retexSuccess)
                    Text("\(progress.completed)/\(progress.total)")
                        .metadataStyle()
                }
                .font(.system(size: 10))
                .foregroundStyle(Color.retexMuted)
            }

            HStack(spacing: 8) {
                if let due = note.dueDate {
                    Label(due, systemImage: "calendar")
                        .metadataStyle()
                }
                Spacer()
                if let value = note.value {
                    Text(value)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.retexText)
                }
            }

            HStack {
                Label(note.owner, systemImage: "person.crop.circle")
                    .metadataStyle()
                Spacer()
                Text(note.url.lastPathComponent)
                    .metadataStyle()
                    .lineLimit(1)
            }
        }
        .padding(13)
        .background(Color.retexSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.retexBorder, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Open card")
        .contextMenu {
            Button("Open card", action: onOpen)
            Button("Archive", role: .destructive, action: onArchive)
        }
    }

    private func tint(for tag: String) -> Color {
        switch tag.lowercased() {
        case "priority": .retexWarning
        case "launch", "product": .retexSuccess
        case "brand": .purple
        case "retained": .orange
        default: .retexAccent
        }
    }
}

private struct DealEditorSheet: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    let note: Note?

    @State private var title: String
    @State private var company: String
    @State private var value: String
    @State private var owner: String
    @State private var status: String
    @State private var due: String
    @State private var tags: String
    @State private var cardBody: String

    init(note: Note?) {
        self.note = note
        _title = State(initialValue: note?.title ?? "")
        _company = State(initialValue: note?.company ?? "")
        _value = State(initialValue: note?.value ?? "")
        _owner = State(initialValue: note?.owner == "Unassigned" ? "" : note?.owner ?? "")
        _status = State(initialValue: note?.status ?? "Inbox")
        _due = State(initialValue: note?.dueDate ?? "")
        _tags = State(initialValue: note?.tags.joined(separator: ", ") ?? "")
        _cardBody = State(initialValue: note?.body ?? "# New deal\n\n## Next actions\n\n- [ ] First follow-up")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(note == nil ? "New card" : "Edit card")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.retexText)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.retexMuted)
                Button(note == nil ? "Create card" : "Save changes") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.retexAccent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)

            Divider().overlay(Color.retexBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("Title") { TextField("Project or opportunity", text: $title) }
                    HStack(alignment: .top, spacing: 12) {
                        field("Company") { TextField("Company", text: $company) }
                        field("Value") { TextField("$0", text: $value) }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        field("Owner") { TextField("Owner", text: $owner) }
                        field("Due date") { TextField("YYYY-MM-DD", text: $due) }
                    }
                    field("List") {
                        Picker("List", selection: $status) {
                            ForEach(BoardColumn.defaultColumns) { column in
                                Text(column.title).tag(column.title)
                            }
                        }
                        .labelsHidden()
                    }
                    field("Labels") {
                        TextField("crm, priority, website", text: $tags)
                    }
                    field("Description and checklist") {
                        TextEditor(text: $cardBody)
                            .font(.system(size: 13, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 220)
                            .padding(10)
                            .background(Color.retexCanvas)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.retexBorder, lineWidth: 1)
                            }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 620, minHeight: 700)
        .background(Color.retexSidebar)
        .preferredColorScheme(.dark)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.retexMuted)
            content()
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        let tagList = tags.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let serializedTags = tagList.isEmpty ? "" : "[\(tagList.joined(separator: ", "))]"

        if let note {
            workspace.updateDeal(
                note,
                title: title,
                company: company,
                value: value,
                owner: owner,
                status: status,
                due: due,
                tags: serializedTags,
                body: cardBody
            )
        } else {
            workspace.createDeal(
                title: title,
                company: company,
                value: value,
                owner: owner,
                status: status,
                due: due,
                tags: serializedTags,
                body: cardBody
            )
        }
        dismiss()
    }
}
