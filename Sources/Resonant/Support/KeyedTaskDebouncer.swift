import Foundation

@MainActor
final class KeyedTaskDebouncer<Key: Hashable> {
    private struct Entry {
        let token: UUID
        let task: Task<Void, Never>
    }

    private var entries: [Key: Entry] = [:]

    func schedule(
        key: Key,
        delay: Duration,
        priority: TaskPriority = .background,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        entries[key]?.task.cancel()

        let token = UUID()
        let task = Task(priority: priority) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await operation()
            await MainActor.run {
                self?.clear(key: key, token: token)
            }
        }

        entries[key] = Entry(token: token, task: task)
    }

    func cancel(key: Key) {
        entries[key]?.task.cancel()
        entries[key] = nil
    }

    func cancelAllAndWait() async {
        let tasks = entries.values.map(\.task)
        entries.removeAll()
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
    }

    private func clear(key: Key, token: UUID) {
        guard entries[key]?.token == token else { return }
        entries[key] = nil
    }
}
