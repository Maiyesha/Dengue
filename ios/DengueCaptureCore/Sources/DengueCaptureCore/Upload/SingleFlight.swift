import Foundation

/// Coalesces concurrent calls: while an operation is in flight, later callers await the same result instead
/// of starting another one. Once it finishes, the next call starts a fresh operation.
/// Used for device-token renew/enrol so concurrent wakes never enrol twice or lose a token update.
public final class SingleFlight<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: (generation: Int, task: Task<T, Never>)?
    private var generation = 0
    private var joins = 0

    public init() {}

    /// Total number of `run` calls (for tests).
    var joinedCount: Int { lock.lock(); defer { lock.unlock() }; return joins }

    public func run(_ op: @escaping () async -> T) async -> T {
        lock.lock()
        joins += 1
        let task: Task<T, Never>
        if let c = current {
            task = c.task
        } else {
            generation += 1
            let gen = generation
            task = Task { [weak self] in
                let v = await op()
                self?.finish(gen)
                return v
            }
            current = (gen, task)
        }
        lock.unlock()
        return await task.value
    }

    private func finish(_ gen: Int) {
        lock.lock(); defer { lock.unlock() }
        if current?.generation == gen { current = nil }
    }
}
