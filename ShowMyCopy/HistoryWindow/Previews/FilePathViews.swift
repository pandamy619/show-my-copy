import AppKit
import SwiftUI

/// Where the files of a files row are, shown on hover: the first paths, one per line, and how many more there are
/// (`FilePathDisplay.list(of:)`). Other rows have no hover text. A password is never a file; a concealed entry gets
/// none all the same.
struct FilePathsHelp: ViewModifier {
    let entry: ClipboardEntry

    @ViewBuilder
    func body(content: Content) -> some View {
        if !entry.isConcealed, case .files(let files) = entry.content, !files.isEmpty {
            let list = FilePathDisplay.current.list(of: files)
            let more = list.more > 0 ? [String(localized: "and \(list.more) more")] : []
            content
                .help(Text(verbatim: (list.paths + more).joined(separator: "\n")))
        } else {
            content
        }
    }
}

/// Tells VoiceOver the folder of a file in the preview, after its name.
struct FolderAccessibilityValue: ViewModifier {
    let folder: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let folder {
            content
                .accessibilityValue(Text("In folder \(folder)"))
        } else {
            content
        }
    }
}

/// A file's folder in the preview: one line in the caption font, cut in the middle when it is too long, as Finder
/// cuts paths, with the whole of it on hover. It can be selected and copied by hand.
///
/// ⌘C and Copy in its menu go to `onCopy`, which puts the text on the clipboard without recording it
/// (`EntryCopying.copyText(_:)`); nothing else is copied. Its menu holds Copy only, without Look Up, Services or
/// Share, which would hand the path to another app. Esc calls `onEscape`, which gives the keys back to the search
/// field.
struct SelectablePathText: NSViewRepresentable {
    let text: String
    let onCopy: @MainActor (String) -> Void
    let onEscape: @MainActor () -> Void

    func makeNSView(context: Context) -> PathTextField {
        let field = PathTextField(frame: .zero)
        field.isEditable = false
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.font = NSFont.preferredFont(forTextStyle: .caption1)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.allowsExpansionToolTips = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        update(field)
        return field
    }

    func updateNSView(_ field: PathTextField, context: Context) {
        update(field)
    }

    /// As wide as the text, or as the room there is when that is less: the text is then cut in the middle.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: PathTextField, context: Context) -> CGSize? {
        let natural = field.intrinsicContentSize
        let width = proposal.width.map { min($0, natural.width) } ?? natural.width
        return CGSize(width: width, height: natural.height)
    }

    private func update(_ field: PathTextField) {
        if field.stringValue != text {
            field.stringValue = text
        }
        field.editor.onCopy = onCopy
        field.editor.onEscape = onEscape
    }
}

/// The text field of `SelectablePathText`. Selecting text in a field happens in a field editor; this field brings
/// its own (`PathFieldCell`), so the window's shared one, which the search field uses, keeps its usual menu and
/// copying.
final class PathTextField: NSTextField {
    let editor: PathFieldEditor = {
        let editor = PathFieldEditor()
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.usesFontPanel = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        return editor
    }()

    override static var cellClass: AnyClass? {
        get { PathFieldCell.self }
        set {}
    }
}

/// Hands the window the field editor of its `PathTextField`. It keeps no state of its own: AppKit copies cells
/// byte for byte, which a stored Swift reference would not survive.
final class PathFieldCell: NSTextFieldCell {
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        (controlView as? PathTextField)?.editor
    }
}

/// The field editor of a `PathTextField`. Copying goes to `onCopy` instead of the pasteboard, and its menu holds
/// Copy only.
final class PathFieldEditor: NSTextView {
    var onCopy: (@MainActor (String) -> Void)?
    var onEscape: (@MainActor () -> Void)?

    /// Without `onCopy` nothing is copied: a plain copy would be recorded as one from the app in front.
    override func copy(_ sender: Any?) {
        let text =
            selectedRanges
            .map { (string as NSString).substring(with: $0.rangeValue) }
            .joined()
        guard !text.isEmpty else {
            return
        }
        onCopy?(text)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.allowsContextMenuPlugIns = false
        menu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
        return menu
    }

    /// Offers the selection to no service, so the Services menu and its shortcuts cannot send it to another app.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        nil
    }
}
