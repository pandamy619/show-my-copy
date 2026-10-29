import Foundation

/// Makes the settings window from what it shows. The real window is built with SwiftUI and includes the shortcut
/// recorder, so it comes from `AppServices`, and `AppContainer` depends on neither.
typealias SettingsWindowFactory = @MainActor (AppSettings) -> any SettingsWindowShowing

/// The services the app runs on that `AppContainer` does not pick itself: the system's clock, pasteboard,
/// notifications and session state, and what needs a macOS-only framework (images, previews, memory, the shortcut
/// recorder). The app passes the real ones (`AppServices.live`, next to the macOS implementations), tests pass fakes
/// from the test target. A new service is a field here, in the group it belongs to, and is used in `AppContainer`.
struct AppServices {
    /// The clock, the system's state and its notifications.
    struct System {
        var now: @MainActor () -> Date
        var frontmostApp: @MainActor () -> SourceApp?
        /// How polling sleeps between looks at the pasteboard.
        var sleep: @Sendable (Duration) async throws -> Void
        var pollingActivity: any PollingActivity
        var workspaceNotifications: any NotificationObserving
        var distributedNotifications: any NotificationObserving
        var isScreenLocked: @MainActor () -> Bool
        var isSessionActive: @MainActor () -> Bool
        /// The apps open now, offered in Settings → Excluded apps.
        var runningApps: any RunningAppsListing
    }

    /// Images, thumbnails and previews. Each is nil when it is not available: then images are not recorded, files
    /// keep their icons or previews show no image or styled text.
    struct Media {
        /// Where image data and thumbnails are kept. The history store must delete blobs in this same store, so it
        /// never deletes those that background work is about to hand to it.
        var blobs: InFlightBlobStore?
        var thumbnails: (any ImageThumbnailMaking)?
        var fileThumbnails: (any FileThumbnailMaking)?
        var previewImages: (any PreviewImageDecoding)?
        var previewRichText: (any RichTextRendering)?

        /// No images, thumbnails or previews.
        static let none = Media()

        init(
            blobs: InFlightBlobStore? = nil,
            thumbnails: (any ImageThumbnailMaking)? = nil,
            fileThumbnails: (any FileThumbnailMaking)? = nil,
            previewImages: (any PreviewImageDecoding)? = nil,
            previewRichText: (any RichTextRendering)? = nil
        ) {
            self.blobs = blobs
            self.thumbnails = thumbnails
            self.fileThumbnails = fileThumbnails
            self.previewImages = previewImages
            self.previewRichText = previewRichText
        }
    }

    var pasteboard: any PasteboardReading & PasteboardWriting
    var system: System
    var media: Media
    /// Reads the app's memory for Settings → Storage.
    var memoryReader: any MemoryUsageReading
    /// The app's login item, for Settings → General → Open at login.
    var loginItem: any LoginItemService
    var makeSettingsWindow: SettingsWindowFactory
}

/// Everything the settings window shows and changes, built by `AppContainer`. A new setting is a field here, made in
/// `AppContainer`, and read by the view that shows it; the initializers in between pass this along unchanged.
@MainActor
struct AppSettings {
    /// The history the settings show and change.
    let store: any HistoryStore
    let history: HistorySettings
    let passwords: PasswordSettings
    /// What the history takes and whether saving it works. Lives as long as the app, so its caches and last
    /// readings survive closing the window.
    let storage: StorageUsage
    /// Whether the app opens at login. Lives as long as the app, so the first launch's suggestion reaches the window.
    let launchAtLogin: LaunchAtLoginSettings
    /// The apps whose copies are never recorded. The clipboard monitor reads the same object.
    let excludedApps: ExcludedApps
}
