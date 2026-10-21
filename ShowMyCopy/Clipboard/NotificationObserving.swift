import Foundation

/// Calls a handler on the main actor when a notification is posted. Lets tests post notifications without the
/// system notification centers.
@MainActor
protocol NotificationObserving: AnyObject {
    func observe(_ name: Notification.Name, handler: @escaping @MainActor @Sendable () -> Void)
    func removeAllObservers()
}

/// Block observers on a local center, such as `NSWorkspace.shared.notificationCenter`, which AppKit posts to on
/// the main thread.
@MainActor
final class NotificationCenterObserver: NotificationObserving {
    private let center: NotificationCenter
    private let queue: OperationQueue?
    private var tokens: [any NSObjectProtocol] = []

    /// A nil queue runs the handler on the posting thread, which must then be the main thread.
    init(center: NotificationCenter, queue: OperationQueue? = .main) {
        self.center = center
        self.queue = queue
    }

    func observe(_ name: Notification.Name, handler: @escaping @MainActor @Sendable () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: queue) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
        tokens.append(token)
    }

    func removeAllObservers() {
        for token in tokens {
            center.removeObserver(token)
        }
        tokens.removeAll()
    }
}
