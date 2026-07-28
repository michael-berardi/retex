import SwiftUI
import RetexCore

struct NotesView: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .compact {
            compactLayout
        } else {
            desktopLayout
        }
    }

    private var desktopLayout: some View {
        HStack(spacing: 0) {
            noteList
                .frame(width: 300)

            Rectangle()
                .fill(Color.retexBorder)
                .frame(width: 1)

            if let note = workspace.selectedNote {
                NoteEditor(note: note)
                    .id(note.id)
            } else {
                EmptyState(
                    symbol: "doc.text",
                    title: "Select a note",
                    message: "Choose a Markdown file from the list."
                )
                .padding(28)
            }
        }
    }

    private var compactLayout: some View {
        NavigationStack {
            List(workspace.visibleNotes) { note in
                NavigationLink {
                    NoteEditor(note: note)
                } label: {
                    NoteRow(note: note)
                }
            }
            .navigationTitle("Notes")
        }
    }

    private var noteList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Notes")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.retexText)
                Text("\(workspace.visibleNotes.count) Markdown files")
                    .metadataStyle()
            }
            .padding(18)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(workspace.visibleNotes) { note in
                        Button {
                            workspace.selectedNoteID = note.id
                        } label: {
                            NoteRow(note: note)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background(
                                    workspace.selectedNoteID == note.id
                                        ? Color.retexAccent.opacity(0.11)
                                        : Color.clear
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .background(Color.retexSidebar)
    }
}

private struct NoteEditor: View {
    @EnvironmentObject private var workspace: WorkspaceModel
    let note: Note
    @State private var draft: String
    @State private var isSaved = true

    init(note: Note) {
        self.note = note
        _draft = State(initialValue: note.body)
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader

            Rectangle()
                .fill(Color.retexBorder)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    propertyGrid

                    TextEditor(text: $draft)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(Color.retexText)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 460)
                        .padding(14)
                        .background(Color.retexSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.retexBorder, lineWidth: 1)
                        }
                        .onChange(of: draft) { _, newValue in
                            isSaved = newValue == note.body
                        }
                }
                .padding(28)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .background(Color.retexCanvas)
    }

    private var editorHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.retexText)
                    .lineLimit(1)
                Text(note.url.path)
                    .metadataStyle()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isSaved {
                Label("Saved", systemImage: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.retexMuted)
            }
            Button("Save") {
                workspace.saveBody(draft, for: note)
                isSaved = true
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.retexAccent)
            .disabled(isSaved)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
        .background(Color.retexSidebar)
    }

    private var propertyGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Properties")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.retexMuted)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], spacing: 8) {
                ForEach(note.metadata.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(key.uppercased())
                            .metadataStyle()
                        Text(note.metadata[key, default: ""])
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.retexText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(Color.retexRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }
}
