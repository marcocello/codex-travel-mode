import AppKit
import SwiftUI

struct LifecycleHero: View {
    let content: MenuBarLifecycleContent
    let message: String

    private var tint: Color {
        Color(nsColor: content.tint)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: content.symbolName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(tint.opacity(0.13))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(content.header)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color(nsColor: .labelColor))
                    .accessibilityIdentifier("travel.lifecycle-header")

                Text(message)
                    .font(.caption)
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("travel.lifecycle-status")
            }

            Spacer(minLength: 0)
        }
    }
}

struct MenuBarCard<Content: View>: View {
    let title: String?
    let tint: Color?
    let content: Content

    init(
        _ title: String? = nil,
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var cardBackground: Color {
        if let tint {
            return tint.opacity(0.07)
        }
        return Color(nsColor: .controlBackgroundColor).opacity(0.72)
    }

    private var borderColor: Color {
        tint?.opacity(0.28) ?? Color(nsColor: .separatorColor).opacity(0.72)
    }
}

enum ReadinessLevel {
    case ready
    case attention
    case neutral

    var symbolName: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .neutral: "minus.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ready: Color(nsColor: .systemGreen)
        case .attention: Color(nsColor: .systemOrange)
        case .neutral: Color(nsColor: .tertiaryLabelColor)
        }
    }
}

struct ReadinessRow: View {
    let title: String
    let value: String
    let level: ReadinessLevel
    let identifier: String
    let semanticValue: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: level.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(level.color)
                .frame(width: 14)
                .accessibilityHidden(true)

            Text(title)
                .font(.caption)
                .foregroundColor(Color(nsColor: .secondaryLabelColor))

            Spacer(minLength: 8)

            Text(value)
                .font(.caption.weight(.medium))
                .foregroundColor(Color(nsColor: .labelColor))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier(identifier)
                .accessibilityValue(semanticValue)
        }
    }
}

struct SessionStatusRow: View {
    let title: String
    let value: String
    let identifier: String
    let semanticValue: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundColor(Color(nsColor: .secondaryLabelColor))
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundColor(Color(nsColor: .labelColor))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier(identifier)
                .accessibilityValue(semanticValue)
        }
    }
}
