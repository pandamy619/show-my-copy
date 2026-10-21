import Foundation

/// Observes distributed notifications, such as the screen lock and unlock notifications.
///
/// AppKit suspends distributed notifications while the app is not active, which is nearly always for this app.
/// Observers registered with the block API then get them late, or only when the app is next activated, and a
/// held unlock notification would keep recording paused. Only the selector API takes `.deliverImmediately`,
/// which delivers them right away even while suspended.
@MainActor
final class DistributedNotificationObserver: NSObject, NotificationObserving {
    private let center: DistributedNotificationCenter
    private var handlers: [Notification.Name: @MainActor @Sendable () -> Void] = [:]

    init(center: DistributedNotificationCenter = .default()) {
        self.center = center
        super.init()
    }

    func observe(_ name: Notification.Name, handler: @escaping @MainActor @Sendable () -> Void) {
        if handlers[name] == nil {
            center.addObserver(
                self,
                selector: #selector(receive(_:)),
                name: name,
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }
        handlers[name] = handler
    }

    func removeAllObservers() {
        center.removeObserver(self)
        handlers.removeAll()
    }

    @objc
    private nonisolated func receive(_ notification: Notification) {
        let name = notification.name
        // The delivery thread is not documented for distributed notifications, so hop to the main actor.
        Task { @MainActor [weak self] in
            self?.handlers[name]?()
        }
    }
}
