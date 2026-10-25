import AppKit
import SwiftUI

extension Image {
    /// Draws an image decoded by `ImageIOPreviewDecoder`. Nil for any other kind of `PreviewImage`.
    init?(preview: any PreviewImage) {
        guard let image = preview as? CGPreviewImage else {
            return nil
        }
        self.init(decorative: image.cgImage, scale: 1)
    }
}

/// The thumbnail at the start of an image row. Loaded when the row appears, off the main actor; a placeholder is
/// shown meanwhile and when there is none. Hidden from VoiceOver: the row's label says what the image is.
struct EntryThumbnail: View {
    static let size: CGFloat = 44

    let image: ImageReference
    let provider: ThumbnailProvider
    @State private var state: PreviewLoadState<any PreviewImage>

    init(image: ImageReference, provider: ThumbnailProvider) {
        self.image = image
        self.provider = provider
        // A row that scrolls back into view shows a cached thumbnail at once, without a placeholder in between.
        _state = State(initialValue: provider.state(for: image))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.quaternary)
            if let loaded = state.value, let drawn = Image(preview: loaded) {
                drawn
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: state.isFailed ? "photo.badge.exclamationmark" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityHidden(true)
        // Keyed by the whole reference: an image recorded before its data was saved gets its thumbnail a moment
        // later, in the same row.
        .task(id: image) {
            state = provider.state(for: image)
            guard state.isLoading, image.isSaved else {
                return
            }
            let loaded = await provider.thumbnail(for: image)
            state = loaded.map { .loaded($0) } ?? .failed
        }
    }
}

/// The icon of a copied file.
struct FileIcon: View {
    let path: String
    let size: CGFloat
    let icons: any FileIconProviding

    var body: some View {
        Image(nsImage: icons.icon(forPath: path))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The mark on a file that may have been moved or deleted.
struct FileUnavailableMark: View {
    let label: Text

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .symbolRenderingMode(.multicolor)
            .help(label)
            .accessibilityLabel(label)
    }
}

/// The names of the copied files, how many there are when there are several, and a mark when any of them may be
/// unavailable. The files are checked when the row appears, off the main actor, not for the whole history.
struct FileRowTitle: View {
    let entryID: ClipboardEntry.ID
    let files: [FileReference]
    let names: String
    let model: HistoryWindowModel
    @State private var availability: FileAvailability?

    var body: some View {
        HStack(spacing: 6) {
            if files.count == 1 {
                Text(verbatim: names)
                    .accessibilityLabel(fileAccessibilityLabel(name: names, thumbnail: files.first?.thumbnail))
            } else {
                Text(verbatim: names)
                Text("\(files.count) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if availability == .mayBeUnavailable {
                FileUnavailableMark(
                    label: files.count == 1
                        ? Text("May have been moved or deleted") : Text("Some files may have been moved or deleted")
                )
            }
        }
        .task(id: entryID) {
            availability = await model.availability(of: files)
        }
    }
}

/// VoiceOver: a hint and an action to open the preview of an entry that has one.
struct PreviewAccessibility: ViewModifier {
    let entry: ClipboardEntry
    let model: HistoryWindowModel

    @ViewBuilder
    func body(content: Content) -> some View {
        if EntryPreviewModel.canPreview(entry) {
            content
                .accessibilityHint(Text("Right Arrow shows a preview."))
                .accessibilityAction(named: Text("Show Preview")) {
                    model.showPreview(of: entry)
                }
        } else {
            content
        }
    }
}

/// The large preview of one entry, over the list. Closed with the button, Left Arrow or Esc.
struct EntryPreviewPane: View {
    let entry: ClipboardEntry
    let preview: EntryPreviewModel
    let thumbnails: ThumbnailProvider
    let icons: any FileIconProviding
    let onClose: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Preview"))
        .accessibilityHint(Text("Left Arrow or Esc closes the preview."))
    }

    private var header: some View {
        HStack(spacing: 8) {
            title
                .font(.headline)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Close Preview")
            .accessibilityLabel("Close Preview")
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private var title: Text {
        switch entry.content {
        case .text:
            Text("Text")
        case .richText:
            Text("Rich text")
        case .image:
            Text("Image")
        case .files(let files):
            Text("\(files.count) files")
        }
    }

    /// The format, size and file size of an image. Not localized, like the image row.
    private var detail: String? {
        guard case .image(let image) = entry.content else {
            return nil
        }
        return "\(entry.previewText) · \(ByteCount.fileSize(image.byteSize))"
    }

    @ViewBuilder private var content: some View {
        switch preview.content {
        case .text(let text):
            PlainTextPreview(text: text, note: nil)
        case .richText(let state, let plain):
            if let rendered = state.value as? AppKitRenderedRichText {
                RichTextPreview(text: rendered.attributedString)
                    .accessibilityLabel(Text("Rich text"))
            } else {
                PlainTextPreview(text: plain, note: state.isFailed ? Text("Shown without formatting") : nil)
            }
        case .image(_, let state):
            imagePreview(state)
        case .files(let items):
            FilesPreview(items: items, thumbnails: thumbnails, icons: icons)
        case nil:
            Color.clear
        }
    }

    @ViewBuilder private func imagePreview(_ state: PreviewLoadState<any PreviewImage>) -> some View {
        if let decoded = state.value, let drawn = Image(preview: decoded) {
            drawn
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                // Never larger than the image: a small icon is not blown up into a blur.
                .frame(maxWidth: CGFloat(decoded.pixelWidth), maxHeight: CGFloat(decoded.pixelHeight))
                .padding(14)
                .accessibilityLabel(Text("Image, \(entry.previewText)"))
                .accessibilityAddTraits(.isImage)
        } else if state.isLoading {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("Loading preview"))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.largeTitle)
                    .accessibilityHidden(true)
                Text("Image unavailable")
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// Plain text in the preview, with line breaks.
private struct PlainTextPreview: View {
    let text: String
    let note: Text?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let note {
                    note
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if text.isEmpty {
                    Text("Blank text")
                        .italic()
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }
}

/// The copied files, with their thumbnails or icons, sizes and a mark on those that may be unavailable.
private struct FilesPreview: View {
    let items: [FilePreviewItem]
    let thumbnails: ThumbnailProvider
    let icons: any FileIconProviding

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        FileThumbnailIcon(
                            path: item.path, thumbnail: item.thumbnail, size: 32, provider: thumbnails, icons: icons)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .accessibilityLabel(fileAccessibilityLabel(name: item.name, thumbnail: item.thumbnail))
                            if let size = item.byteSize {
                                Text(verbatim: ByteCount.fileSize(size))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        if item.availability == .mayBeUnavailable {
                            FileUnavailableMark(label: Text("May have been moved or deleted"))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(6)
        }
    }
}

/// Styled text drawn by AppKit, on white like a page, so its own colours stay readable in Dark Mode. Not editable
/// and not selectable, so keyboard focus stays in the search field; the text holds no links (see
/// `AppKitRichTextRenderer`), and link and data detection are off.
private struct RichTextPreview: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.appearance = NSAppearance(named: .aqua)
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = false
            textView.importsGraphics = false
            textView.isAutomaticLinkDetectionEnabled = false
            textView.isAutomaticDataDetectionEnabled = false
            textView.drawsBackground = true
            textView.backgroundColor = .white
            textView.textContainerInset = NSSize(width: 10, height: 10)
            textView.textStorage?.setAttributedString(text)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, let storage = textView.textStorage,
            !storage.isEqual(to: text)
        else {
            return
        }
        storage.setAttributedString(text)
    }
}
