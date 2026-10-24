import Foundation

@testable import ShowMyCopy

/// Builds the clipboard monitors of the tests, so a new dependency of the monitor is added here once instead of in
/// every test file. Every default is a fake: no app is in front, the clock stands still, the polling loop never
/// wakes up on its own and App Nap is never touched.
@MainActor
enum MonitorFactory {
    /// The time a monitor reads unless a test sets one: months after the dates the tests record entries at, as the
    /// real clock is, so an entry a test recorded is never taken for one copied a moment ago.
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func make(
        pasteboard: any PasteboardReading,
        history: any HistoryStore,
        frontmostApp: @escaping @MainActor () -> SourceApp? = { nil },
        now: @escaping @MainActor () -> Date = { MonitorFactory.date },
        passwordPolicy: @escaping @MainActor () -> PasswordPolicy = { .default },
        interval: Duration = PollingSchedule.defaultInterval,
        sleep: @escaping @Sendable (Duration) async throws -> Void = MonitorFactory.sleepUntilCancelled,
        activity: any PollingActivity = CountingActivity(),
        activityClock: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        blobs: InFlightBlobStore? = nil,
        imageIngestor: ImageIngestor? = nil,
        fileSizes: FileSizeReader = MonitorFactory.noFileSizes,
        fileThumbnailIngestor: FileThumbnailIngestor? = nil
    ) -> ClipboardMonitor {
        ClipboardMonitor(
            pasteboard: pasteboard,
            history: history,
            schedule: PollingSchedule(interval: interval, sleep: sleep, activity: activity, now: activityClock),
            expiry: PasswordExpiry(history: history, now: now),
            clearedClipboard: ClearedClipboardCheck(history: history),
            capture: blobs.map { blobs in
                CaptureEnrichment(
                    history: history, blobs: blobs, images: imageIngestor, fileSizes: fileSizes,
                    fileThumbnails: fileThumbnailIngestor)
            },
            frontmostApp: frontmostApp,
            now: now,
            passwordPolicy: passwordPolicy
        )
    }

    /// Reads no file: every size is unknown, as for files the sandbox hides.
    nonisolated static let noFileSizes = FileSizeReader(
        paths: CopiedPaths(volumes: FakeVolumes.startupDiskOnly), size: { _ in nil })

    /// A sleep that never ends on its own: it returns only by throwing when its task is cancelled, as when the
    /// monitor stops. Tests that need the loop to run use `ManualSleeper`.
    nonisolated static func sleepUntilCancelled(_ duration: Duration) async throws {
        await suspendUntilCancelled()
        throw CancellationError()
    }
}
