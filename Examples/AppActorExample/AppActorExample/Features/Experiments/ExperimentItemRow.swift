import SwiftUI
import AppActor

struct ExperimentItemRow: View {
	let assignment: AppActorExperimentAssignment

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			// Experiment key + variant
			HStack(spacing: 10) {
				Image(systemName: "flask.fill")
					.font(.system(size: 14, weight: .semibold))
					.foregroundStyle(PRTheme.accent)
					.frame(width: 28, height: 28)
					.background(PRTheme.accent.opacity(0.12))
					.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

				VStack(alignment: .leading, spacing: 2) {
					Text(assignment.experimentKey)
						.font(.system(size: 13, weight: .semibold, design: .monospaced))
						.foregroundStyle(.primary)

					Text("variant: \(assignment.variantKey)")
						.font(.system(size: 11, weight: .medium))
						.foregroundStyle(.secondary)
				}

				Spacer()

				// Value type badge
				Text(assignment.valueType.rawValue)
					.font(.system(size: 10, weight: .bold))
					.textCase(.uppercase)
					.padding(.horizontal, 6)
					.padding(.vertical, 2)
					.background(typeColor.opacity(0.15))
					.foregroundStyle(typeColor)
					.clipShape(Capsule())
			}

			// Payload value
			HStack(spacing: 8) {
				Image(systemName: typeIcon)
					.font(.system(size: 12, weight: .semibold))
					.foregroundStyle(typeColor)
					.frame(width: 20)

				Text(displayValue)
					.font(.system(size: 13, weight: .medium, design: .monospaced))
					.foregroundStyle(valueColor)
					.lineLimit(2)
					.truncationMode(.tail)
			}
			.padding(.leading, 38) // Align with text above
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
		.background(Color(.tertiarySystemFill))
		.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
	}

	// MARK: - Helpers

	private var typeIcon: String {
		switch assignment.valueType {
		case .boolean: return "checkmark.circle"
		case .number: return "number"
		case .string: return "textformat"
		case .json: return "curlybraces"
		}
	}

	private var typeColor: Color {
		switch assignment.valueType {
		case .boolean: return PRTheme.success
		case .number: return PRTheme.info
		case .string: return PRTheme.accent
		case .json: return PRTheme.warning
		}
	}

	private var displayValue: String {
		switch assignment.payload {
		case .bool(let v): return v ? "true" : "false"
		case .int(let v): return "\(v)"
		case .double(let v): return "\(v)"
		case .string(let v): return "\"\(v)\""
		case .null: return "null"
		default: return "\(assignment.payload)"
		}
	}

	private var valueColor: Color {
		switch assignment.payload {
		case .bool(let v): return v ? PRTheme.success : PRTheme.error
		case .string: return PRTheme.accent
		case .null: return .secondary
		default: return .primary
		}
	}
}
