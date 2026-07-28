import SwiftUI
import RetexCore

struct ScreenHeader<Actions: View>: View {
    let title: String
    let description: String
    @ViewBuilder let actions: () -> Actions

    init(
        _ title: String,
        description: String,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.description = description
        self.actions = actions
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                headerText
                Spacer(minLength: 20)
                actions()
            }
            VStack(alignment: .leading, spacing: 14) {
                headerText
                actions()
            }
        }
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.7)
                .foregroundStyle(Color.retexText)
            Text(description)
                .font(.system(size: 14))
                .foregroundStyle(Color.retexMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MetricCard: View {
    let label: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.retexAccent)
                Spacer()
                Text(detail.uppercased())
                    .metadataStyle()
            }
            Text(value)
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.retexText)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.retexMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .retexPanel()
    }
}

struct MetadataPill: View {
    let text: String
    var tint: Color = .retexMuted

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(tint.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(tint.opacity(0.2), lineWidth: 1)
            }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Color.retexMuted)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.retexText)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Color.retexMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .retexPanel()
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color.retexMuted)
                .frame(width: 24, height: 24)
                .background(Color.retexRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(note.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.retexText)
                    .lineLimit(1)
                Text(note.url.deletingLastPathComponent().lastPathComponent)
                    .metadataStyle()
                    .lineLimit(1)
            }

            Spacer()
            Text(note.modifiedAt, style: .relative)
                .metadataStyle()
        }
        .contentShape(Rectangle())
    }

    private var symbol: String {
        switch note.type {
        case .deal: "briefcase"
        case .contact: "person"
        case .task: "checkmark.square"
        case .agentRun: "waveform.path.ecg"
        case .note: "doc.text"
        }
    }
}
