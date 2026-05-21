import SwiftUI
import AppActor

struct ExperimentsScreen: View {
	@EnvironmentObject private var appState: AppState
	@StateObject private var vm = ExperimentsViewModel()

	var body: some View {
		ExampleScreen(
			title: "Experiments",
			subtitle: "Experiment assignment sorgula, hedef dışı kalan anahtarları ayır ve sonucu net gör.",
			icon: "flask.fill",
			tint: PRTheme.accent,
			badgeText: vm.assignments.isEmpty ? "No assignments yet" : "Assignments available",
			badgeColor: vm.assignments.isEmpty ? PRTheme.warning : PRTheme.success
		) {
			PRCard {
				VStack(alignment: .leading, spacing: PRTheme.spacing) {
					SectionHeader(
						"Experiment Lookup",
						icon: "flask.fill",
						color: PRTheme.accent,
						subtitle: "Tek bir experiment key girip assignment al"
					)

					PRTextField(
						placeholder: "Experiment Key (e.g. onboarding_v2)",
						text: $vm.experimentKeyInput
					)

					ActionTile(
						title: "Get Assignment",
						icon: "arrow.down.circle.fill",
						color: PRTheme.accent,
						subtitle: "Network çağrısı ile assignment veya exclusion sonucu",
						action: vm.fetchAssignment
					)
				}
			}

			if let date = vm.lastLoadDate {
				PRCard {
					VStack(alignment: .leading, spacing: 8) {
						SectionHeader("Status", icon: "info.circle.fill", color: PRTheme.info)
						InfoRow(
							label: "Assigned",
							value: "\(vm.assignments.count)"
						)
						InfoRow(
							label: "Not Targeted",
							value: "\(vm.notInExperiment.count)"
						)
						InfoRow(
							label: "Last Fetch",
							value: date.formatted(date: .omitted, time: .standard)
						)
					}
				}
			}

			if !vm.assignments.isEmpty {
				PRCard {
					VStack(alignment: .leading, spacing: PRTheme.spacing) {
						SectionHeader(
							"Assignments (\(vm.assignments.count))",
							icon: "flask.fill",
							color: PRTheme.success,
							subtitle: "Server tarafından atanan varyantlar"
						)

						ForEach(Array(vm.assignments.values).sorted(by: { $0.experimentKey < $1.experimentKey }), id: \.experimentKey) { assignment in
							ExperimentItemRow(assignment: assignment)
						}
					}
				}
			}

			if !vm.notInExperiment.isEmpty {
				PRCard {
					VStack(alignment: .leading, spacing: PRTheme.spacing) {
						SectionHeader(
							"Not Targeted (\(vm.notInExperiment.count))",
							icon: "xmark.circle",
							color: PRTheme.error,
							subtitle: "Deneyin hedef kitlesine girmeyen anahtarlar"
						)

						ForEach(Array(vm.notInExperiment).sorted(), id: \.self) { key in
							HStack(spacing: 10) {
								Image(systemName: "minus.circle")
									.font(.system(size: 14, weight: .semibold))
									.foregroundStyle(PRTheme.error)
									.frame(width: 28, height: 28)
									.background(PRTheme.error.opacity(0.12))
									.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

								Text(key)
									.font(.system(size: 13, weight: .semibold, design: .monospaced))
									.foregroundStyle(.primary)

								Spacer()

								Text("Not in experiment")
									.font(.system(size: 12, weight: .medium))
									.foregroundStyle(.secondary)
							}
							.padding(.horizontal, 12)
							.padding(.vertical, 10)
							.background(PRTheme.rowBackground)
							.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
						}
					}
				}
			}
		}
		.onAppear { vm.appState = appState }
	}
}
