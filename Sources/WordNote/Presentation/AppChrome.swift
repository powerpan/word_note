import SwiftUI

struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let actions: Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            verticalLayout
        }
    }

    private var horizontalLayout: some View {
        HStack(alignment: .firstTextBaseline) {
            titleBlock

            Spacer(minLength: 16)
            actions
        }
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleBlock
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(WordNoteTheme.editorialFont(size: 25, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(WordNoteTheme.mutedInk)
                .lineLimit(2)
        }
    }
}

struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 5) {
                Text(title)
                    .font(WordNoteTheme.editorialFont(size: 21, weight: .semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(WordNoteTheme.mutedInk)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct StatusBanner: View {
    enum Kind {
        case success
        case warning
        case info

        var systemImage: String {
            switch self {
            case .success:
                "checkmark.circle"
            case .warning:
                "exclamationmark.triangle"
            case .info:
                "info.circle"
            }
        }

        var tint: Color {
            switch self {
            case .success:
                WordNoteTheme.green
            case .warning:
                WordNoteTheme.amber
            case .info:
                WordNoteTheme.teal
            }
        }
    }

    let message: String
    let kind: Kind

    var body: some View {
        Label(message, systemImage: kind.systemImage)
            .font(.callout)
            .foregroundStyle(kind.tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(kind.tint.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(kind.tint.opacity(0.35), lineWidth: 1)
            }
    }
}

struct TagChip: View {
    let title: String
    var tint: Color = .secondary

    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(tint.opacity(0.65), lineWidth: 1)
            }
    }
}
