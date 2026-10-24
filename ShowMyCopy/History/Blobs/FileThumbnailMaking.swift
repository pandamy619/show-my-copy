import Foundation

/// Makes thumbnails of copied photo and video files. The app uses QuickLook (`QuickLookFileThumbnailMaker`, macOS
/// only), which draws a frame of a video. Both calls happen off the main actor and only while the file was just
/// copied: that is when the sandbox lets the app read it.
protocol FileThumbnailMaking: Sendable {
    /// What the file at `url` is, from its type: a photo, a video, or nil for anything else. Nil also for a file
    /// that is not a regular local file the app can look at, or whose data is not on this Mac, such as an iCloud
    /// file that is not downloaded or a file on a network volume: making its thumbnail could download it. Reads the
    /// file's attributes, never its contents.
    func mediaKind(of url: URL) -> FileThumbnail.Kind?

    /// A PNG thumbnail of the file, at most `maximumPixelSize` pixels on its longer side, or nil when none can be
    /// made. Reads only what the thumbnail needs and keeps nothing of the file. Must return soon after the calling
    /// task is cancelled, which is how a timeout stops it.
    func thumbnail(of url: URL, maximumPixelSize: Int) async -> ImageInspection.Thumbnail?
}
