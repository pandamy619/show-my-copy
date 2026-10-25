import SwiftUI

/// A copied file: the thumbnail of a photo or video when it has one, otherwise its icon, which is also shown while
/// the thumbnail loads and when it cannot be read. A video gets a play badge. Hidden from VoiceOver: the label next
/// to it says what the file is.
struct FileThumbnailIcon: View {
    let path: String
    let thumbnail: FileThumbnail?
    let size: CGFloat
    let provider: ThumbnailProvider
    let icons: any FileIconProviding
    @State private var state: PreviewLoadState<any PreviewImage>

    init(
        path: String,
        thumbnail: FileThumbnail?,
        size: CGFloat,
        provider: ThumbnailProvider,
        icons: any FileIconProviding
    ) {
        self.path = path
        self.thumbnail = thumbnail
        self.size = size
        self.provider = provider
        self.icons = icons
        // A row that scrolls back into view shows a cached thumbnail at once, without the icon in between.
        _state = State(initialValue: thumbnail.map { provider.state(for: $0) } ?? .failed)
    }

    var body: some View {
        ZStack {
            if let loaded = state.value, let drawn = Image(preview: loaded) {
                drawn
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                if thumbnail?.kind == .movie {
                    PlayBadge(size: size)
                }
            } else {
                FileIcon(path: path, size: size, icons: icons)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: thumbnail?.blobID) {
            guard let thumbnail, state.isLoading else {
                return
            }
            let loaded = await provider.thumbnail(for: thumbnail)
            state = loaded.map { .loaded($0) } ?? .failed
        }
    }
}

/// The small play sign on the thumbnail of a video.
private struct PlayBadge: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "play.fill")
            .font(size < 40 ? .caption2.weight(.bold) : .callout.weight(.bold))
            .foregroundStyle(.white)
            .padding(max(size * 0.1, 3))
            .background(Circle().fill(.black.opacity(0.55)))
    }
}

/// What VoiceOver says for one copied file: a photo or video when it has a thumbnail, otherwise a file.
func fileAccessibilityLabel(name: String, thumbnail: FileThumbnail?) -> Text {
    switch thumbnail?.kind {
    case .image:
        Text("Photo, \(name)")
    case .movie:
        Text("Video, \(name)")
    case nil:
        Text("File, \(name)")
    }
}
