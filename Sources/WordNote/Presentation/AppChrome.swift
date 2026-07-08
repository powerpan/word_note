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
                .font(.system(size: 30, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
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
                    .font(.title2.bold())
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct MetricCard: View {
    let title: String
    let value: Int
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(value, format: .number)
                    .font(.system(size: 28, weight: .bold))
                    .monospacedDigit()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                .green
            case .warning:
                .orange
            case .info:
                .blue
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
            .background(kind.tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
