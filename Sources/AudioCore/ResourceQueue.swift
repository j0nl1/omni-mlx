import Foundation

/// A single resource permit shared by all operations using one accelerator.
public actor ResourceQueue {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
        let timer: Task<Void, Never>
    }
    private let capacity: Int
    private var busy = false
    private var blocked = false
    private var waiters: [Waiter] = []

    public init(capacity: Int) { self.capacity = capacity }
    var queuedRequests: Int { waiters.count }
    public func withPermit<T: Sendable>(budget: RequestBudget, operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire(budget)
        defer { release() }
        try budget.check()
        let result = try await operation()
        try budget.check()
        return result
    }
    public func quarantine() {
        blocked = true
        for waiter in waiters { waiter.timer.cancel(); waiter.continuation.resume(throwing: ServiceError.unavailable) }
        waiters.removeAll()
    }
    public func ready() -> Bool { !blocked }

    private func acquire(_ budget: RequestBudget) async throws {
        try budget.check()
        guard !blocked else { throw ServiceError.unavailable }
        if !busy { busy = true; return }
        guard waiters.count < capacity else { throw ServiceError("queue_full", "The audio resource queue is full.", status: 429) }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: ServiceError.cancelled); return }
                let timer = Task {
                    do { try await Task.sleep(until: budget.deadline, clock: .continuous) }
                    catch { return }
                    expire(id, error: .deadline)
                }
                waiters.append(Waiter(id: id, continuation: continuation, timer: timer))
            }
        } onCancel: { Task { await self.expire(id, error: .cancelled) } }
    }
    private func expire(_ id: UUID, error: ServiceError) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.timer.cancel(); waiter.continuation.resume(throwing: error)
    }
    private func release() {
        if waiters.isEmpty { busy = false; return }
        let waiter = waiters.removeFirst()
        waiter.timer.cancel(); waiter.continuation.resume()
    }
}
