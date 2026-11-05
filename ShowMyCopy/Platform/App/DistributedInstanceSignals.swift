import Foundation

/// Posts the signals of `DuplicateLaunch` to the other copies of the app as distributed notifications: the name
/// only, with no object and no `userInfo`.
///
/// The App Sandbox lets an app post a distributed notification only without a dictionary: "If the sending
/// application is in an App Sandbox, `userInfo` must be `nil`" (`DistributedNotificationCenter`,
/// `postNotificationName(_:object:userInfo:deliverImmediately:)`). This needs no entitlement and no Apple events,
/// unlike `NSRunningApplication.terminate()`, which returns false in a sandboxed app. The running copy observes the
/// name with `DistributedNotificationObserver`, which delivers it at once although the app is rarely active.
@MainActor
final class DistributedInstanceSignals: InstanceSignalPosting {
    func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
