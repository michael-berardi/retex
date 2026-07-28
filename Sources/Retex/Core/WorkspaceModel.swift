import Foundation
import SwiftUI
import RetexCore

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var vaults: [Vault] = []
    @Published var selectedVault: Vault? {
        didSet {
            guard selectedVault != oldValue else { return }
            reload()
        }
    }
    @Published private(set) var notes: [Note] = []
    @Published var selectedSection: WorkspaceSection? = .overview
    @Published var selectedNoteID: Note.ID?
    @Published var searchQuery = ""
    @Published var isAddingVault = false
    @Published var errorMessage: String?

    private let store = MarkdownStore()
    private let defaultsKey = "Retex.vaultPaths"

    init() {
        bootstrap()
    }

    var selectedNote: Note? {
        notes.first { $0.id == selectedNoteID }
    }

    var visibleNotes: [Note] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return notes }
        return notes.filter { note in
            note.title.localizedCaseInsensitiveContains(query)
                || note.body.localizedCaseInsensitiveContains(query)
                || note.metadata.values.contains { $0.localizedCaseInsensitiveContains(query) }
                || note.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var deals: [Note] { notes.filter { $0.type == .deal && !$0.isArchived } }
    var contacts: [Note] { notes.filter { $0.type == .contact } }
    var agentRuns: [Note] { notes.filter { $0.type == .agentRun } }

    var pipelineValue: Int {
        deals.reduce(into: 0) { total, deal in
            guard let value = deal.value else { return }
            let digits = value.filter(\.isNumber)
            total += Int(digits) ?? 0
        }
    }

    var activeAgentCount: Int {
        agentRuns.count { ["working", "queued"].contains($0.status.lowercased()) }
    }

    func addVault(_ url: URL) {
        let gainedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if gainedAccess { url.stopAccessingSecurityScopedResource() }
        }

        let vault = Vault(url: url.standardizedFileURL)
        guard !vaults.contains(vault) else {
            selectedVault = vault
            return
        }

        vaults.append(vault)
        vaults.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistVaults()
        selectedVault = vault
    }

    func reload() {
        guard let selectedVault else {
            notes = []
            return
        }

        do {
            notes = try store.scan(selectedVault)
            if selectedNoteID == nil || !notes.contains(where: { $0.id == selectedNoteID }) {
                selectedNoteID = notes.first?.id
            }
            errorMessage = nil
        } catch {
            notes = []
            errorMessage = error.localizedDescription
        }
    }

    func saveBody(_ body: String, for note: Note) {
        do {
            try store.saveBody(body, for: note)
            reloadPreserving(note.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createDeal(
        title: String,
        company: String,
        value: String,
        owner: String,
        status: String,
        due: String,
        tags: String,
        body: String
    ) {
        guard let selectedVault else { return }
        do {
            var metadata = [
                "type": NoteType.deal.rawValue,
                "status": status,
                "rank": nextRank(in: status).formatted(),
            ]
            if !company.isEmpty { metadata["company"] = company }
            if !value.isEmpty { metadata["value"] = value }
            if !owner.isEmpty { metadata["owner"] = owner }
            if !due.isEmpty { metadata["due"] = due }
            if !tags.isEmpty { metadata["tags"] = tags }
            let note = try store.createNote(
                in: selectedVault,
                folder: "Deals",
                title: title,
                metadata: metadata,
                body: body
            )
            reloadPreserving(note.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateDeal(
        _ note: Note,
        title: String,
        company: String,
        value: String,
        owner: String,
        status: String,
        due: String,
        tags: String,
        body: String
    ) {
        do {
            try store.updateMetadata(
                [
                    "title": title,
                    "company": company,
                    "value": value,
                    "owner": owner,
                    "status": status,
                    "due": due,
                    "tags": tags,
                ],
                for: note
            )
            let refreshed = try store.load(note.url)
            try store.saveBody(body, for: refreshed)
            reloadPreserving(note.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func archive(_ note: Note) {
        do {
            try store.updateMetadata("archived", value: "true", for: note)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func move(_ note: Note, to status: String, rank: Double? = nil) {
        do {
            try store.updateMetadata(
                [
                    "status": status,
                    "rank": (rank ?? nextRank(in: status)).formatted(),
                ],
                for: note
            )
            reloadPreserving(note.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(_ note: Note, section: WorkspaceSection = .notes) {
        selectedNoteID = note.id
        selectedSection = section
    }

    private func bootstrap() {
        do {
            let sample = try installSampleVault()
            let storedVaults = UserDefaults.standard.stringArray(forKey: defaultsKey, default: [])
                .map { Vault(url: URL(fileURLWithPath: $0, isDirectory: true)) }
                .filter { FileManager.default.fileExists(atPath: $0.url.path) }

            vaults = Array(Set(storedVaults + [sample])).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            selectedVault = vaults.first { $0.name == "Liberty CRM" } ?? vaults.first
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installSampleVault() throws -> Vault {
        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let vaultsDirectory = applicationSupport.appendingPathComponent("Retex/Vaults", isDirectory: true)
        let destination = vaultsDirectory.appendingPathComponent("Liberty CRM", isDirectory: true)

        if !fileManager.fileExists(atPath: destination.path) {
            guard let source = Bundle.module.url(
                forResource: "Liberty CRM",
                withExtension: nil,
                subdirectory: "SampleVaults"
            ) else {
                throw StoreError.missingSampleVault
            }
            try fileManager.createDirectory(at: vaultsDirectory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
        }

        return Vault(url: destination)
    }

    private func persistVaults() {
        UserDefaults.standard.set(vaults.map(\.url.path), forKey: defaultsKey)
    }

    private func nextRank(in status: String) -> Double {
        let highestRank = deals.filter { $0.status == status }.map(\.rank).max() ?? 0
        return highestRank + 1
    }

    private func reloadPreserving(_ noteID: Note.ID) {
        reload()
        selectedNoteID = noteID
    }
}

private extension UserDefaults {
    func stringArray(forKey defaultName: String, default fallback: [String]) -> [String] {
        stringArray(forKey: defaultName) ?? fallback
    }
}
