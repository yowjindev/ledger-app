import Foundation

/// Runs async work one piece at a time, in the order it was asked for, so a reminder refresh
/// never interleaves with another.
@MainActor
final class SerialRunner {
    private var last: Task<Void, Never>?

    func run(_ work: @escaping @MainActor () async -> Void) async {
        let previous = last
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        last = task
        await task.value
    }
}
