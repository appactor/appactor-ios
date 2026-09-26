import Foundation

/// A one-shot signal: `wait()` suspends until `signal()` has been called once.
/// Lets a test hold a mocked call open while it drives a race.
actor AsyncSignal {
    private var didSignal = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !didSignal else { return }
        didSignal = true
        continuations.forEach { $0.resume() }
        continuations = []
    }

    func wait() async {
        guard !didSignal else { return }
        await withCheckedContinuation { continuations.append($0) }
    }
}
