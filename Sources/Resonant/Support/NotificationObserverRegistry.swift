import Foundation

/// Collects `NotificationCenter` observer tokens so an owner can tear them all
/// down at once. Removing observers as a group prevents duplicate registrations
/// when the owner is re-instantiated (e.g. across tests) and removes the
/// boilerplate of storing one `NSObjectProtocol?` per observer.
///
/// Supports multiple centers (e.g. `.default` and
/// `NSWorkspace.shared.notificationCenter`) in a single registry.
final class NotificationObserverRegistry {
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// Registers a block-based observer and retains its token for `removeAll()`.
    @discardableResult
    func observe(
        _ name: Notification.Name,
        object: Any? = nil,
        queue: OperationQueue? = .main,
        center: NotificationCenter = .default,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> NSObjectProtocol {
        let token = center.addObserver(forName: name, object: object, queue: queue, using: block)
        tokens.append((center, token))
        return token
    }

    /// Removes every registered observer. Safe to call more than once.
    func removeAll() {
        for entry in tokens {
            entry.center.removeObserver(entry.token)
        }
        tokens.removeAll()
    }

    deinit {
        removeAll()
    }
}
