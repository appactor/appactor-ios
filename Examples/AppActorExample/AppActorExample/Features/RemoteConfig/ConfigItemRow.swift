import SwiftUI
import AppActor

struct ConfigItemRow: View {
    let item: AppActorRemoteConfigItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
                .background(iconColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.key)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)

                Text(item.valueType.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text(displayValue)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Helpers

    private var iconName: String {
        switch item.valueType {
        case .boolean: return "checkmark.circle"
        case .number: return "number"
        case .string: return "textformat"
        case .json: return "curlybraces"
        }
    }

    private var iconColor: Color {
        switch item.valueType {
        case .boolean: return PRTheme.success
        case .number: return PRTheme.info
        case .string: return PRTheme.accent
        case .json: return PRTheme.warning
        }
    }

    private var displayValue: String {
        switch item.value {
        case .bool(let v): return v ? "true" : "false"
        case .int(let v): return "\(v)"
        case .double(let v): return "\(v)"
        case .string(let v): return "\"\(v)\""
        case .null: return "null"
        default: return "\(item.value)"
        }
    }

    private var valueColor: Color {
        switch item.value {
        case .bool(let v): return v ? PRTheme.success : PRTheme.error
        case .string: return PRTheme.accent
        case .null: return .secondary
        default: return .primary
        }
    }
}
