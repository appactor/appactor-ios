import Foundation
import AppActor

@MainActor
final class ExperimentsViewModel: ObservableObject {

	@Published var assignments: [String: AppActorExperimentAssignment] = [:]
	@Published var notInExperiment: Set<String> = []
	@Published var lastLoadDate: Date?
	@Published var experimentKeyInput: String = ""

	weak var appState: AppState?

	init(appState: AppState? = nil) {
		self.appState = appState
	}

	func fetchAssignment() {
		let key = experimentKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !key.isEmpty else {
			appState?.errorMessage = "Enter an experiment key above."
			return
		}
		guard let appState, appState.ensureConfigured() else { return }
		appState.isLoading = true
		Task {
			do {
				if let assignment = try await AppActor.shared.getExperimentAssignment(experimentKey: key) {
					assignments[key] = assignment
					notInExperiment.remove(key)
					appState.logStore.log("experiment('\(key)') → variant '\(assignment.variantKey)'")
				} else {
					assignments.removeValue(forKey: key)
					notInExperiment.insert(key)
					appState.logStore.log("experiment('\(key)') → not in experiment")
				}
				lastLoadDate = Date()
				appState.refreshState()
			} catch {
				appState.showError(error)
			}
			appState.isLoading = false
		}
	}

	func clearAll() {
		assignments.removeAll()
		notInExperiment.removeAll()
		lastLoadDate = nil
	}
}
