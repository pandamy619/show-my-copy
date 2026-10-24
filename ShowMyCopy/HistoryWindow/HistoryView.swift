import AppKit
import SwiftUI

/// Search field and clipboard history list shown in the history panel.
struct HistoryView: View {
    @Bindable var model: HistoryWindowModel
    let onChoose: @MainActor (ClipboardEntry) -> Void
    let onClose: @MainActor () -> Void
    let onOpenSettings: @MainActor () -> Void

    @FocusState private var isSearchFocused: Bool

    private let icons: any FileIconProviding = WorkspaceFileIconProvider()

    var body: some View {
        let items = model.items
        let selectedID = model.selectedIndex(in: items).map { items[$0].id }
        VStack(spacing: 0) {
            searchBar
            Divider()
            if items.isEmpty {
                // The window controller shrinks the panel to exactly these rows.
                emptyState
            } else {
                let previewed = model.previewedEntry
                // The list stays underneath the preview, so it keeps its scroll position.
                list(items: items, selectedID: selectedID, now: Date())
                    .opacity(previewed == nil ? 1 : 0)
                    .allowsHitTesting(previewed == nil)
                    .accessibilityHidden(previewed != nil)
                    .overlay {
                        if let previewed {
                            EntryPreviewPane(
                                entry: previewed, preview: model.preview, thumbnails: model.thumbnails, icons: icons
                            ) {
                                model.preview.close()
                            }
                        }
                    }
            }
        }
        // Follow the panel's size: compact with nothing to list, full with entries. Pinned to the top, so the
        // search bar stays in place while the panel catches up with a change.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The panel's title bar is hidden and transparent. Start at the top edge instead of below it; the list
        // scrolls inside the content under the search bar, so it keeps its own insets.
        .ignoresSafeArea()
        .defaultFocus($isSearchFocused, true)
        .onAppear { isSearchFocused = true }
        .onChange(of: model.presentationCount) { isSearchFocused = true }
        .onKeyPress(keys: Self.handledKeys) { handleKey($0) }
        .onExitCommand { onClose() }
    }

    private static let handledKeys: Set<KeyEquivalent> = [
        .upArrow, .downArrow, .leftArrow, .rightArrow, .return, .escape,
    ]

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFocused)
                .onKeyPress(keys: Self.handledKeys) { handleKey($0) }
                .onSubmit { chooseSelected() }
            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 14)
        .frame(height: HistoryPanelPlacement.searchBarHeight)
    }

    /// One slim row under the search bar, like Spotlight with no results.
    private var emptyState: some View {
        let isHistoryEmpty = model.history.entries.isEmpty
        return HStack(spacing: 8) {
            Image(systemName: isHistoryEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .accessibilityHidden(true)
            (isHistoryEmpty ? Text("Nothing copied yet") : Text("No matches"))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: HistoryPanelPlacement.messageRowHeight)
    }

    private func list(items: [ClipboardEntry], selectedID: ClipboardEntry.ID?, now: Date) -> some View {
        // The current entry, when there is one, is the newest. After a skipped copy (a password, an image) nothing
        // in the history is on the clipboard, so every entry is listed under "History".
        let current = items.first.flatMap { $0.id == model.currentEntryID ? $0 : nil }
        let rest = current == nil ? items[...] : items.dropFirst()
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let current {
                        sectionHeader("Current clipboard")
                        row(current, selectedID: selectedID, now: now)
                        Divider()
                            .padding(.vertical, 4)
                    }
                    if !rest.isEmpty {
                        sectionHeader("History")
                        ForEach(rest) { entry in
                            row(entry, selectedID: selectedID, now: now)
                        }
                    }
                }
                .padding(6)
            }
            .onChange(of: selectedID) {
                if let selectedID {
                    proxy.scrollTo(selectedID)
                }
            }
            .onChange(of: model.presentationCount) {
                if let first = items.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ entry: ClipboardEntry, selectedID: ClipboardEntry.ID?, now: Date) -> some View {
        let isSelected = entry.id == selectedID
        let isRevealed = model.isRevealed(entry.id)
        // The eye button sits next to the row's button, not inside it: a button inside another button's label
        // would also choose the entry.
        return HStack(spacing: 0) {
            Button {
                onChoose(entry)
            } label: {
                HistoryRow(
                    entry: entry, isRevealed: isRevealed, isSelected: isSelected, now: now, model: model, icons: icons)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if EntryPreviewModel.canPreview(entry) {
                    Button("Show Preview") {
                        model.showPreview(of: entry)
                    }
                }
            }
            .modifier(PreviewAccessibility(entry: entry, model: model))
            if entry.isConcealed {
                RevealButton(isRevealed: isRevealed) {
                    model.toggleReveal(entry.id)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .id(entry.id)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // While an input method composes text (Japanese, Chinese, Korean), these keys move between and confirm
        // its candidates or cancel the composition. Leave them to the search field.
        guard !Self.isComposingText else {
            return .ignored
        }
        guard let key = Self.historyKey(for: press) else {
            return .ignored
        }
        switch model.handleKey(key, isCaretAtEnd: Self.isCaretAtEnd) {
        case .handled:
            return .handled
        case .ignored:
            return .ignored
        case .choose(let entry):
            onChoose(entry)
            return .handled
        case .close:
            onClose()
            return .handled
        }
    }

    /// The model's name for a key press, or nil for one the history window leaves to the search field.
    private static func historyKey(for press: KeyPress) -> HistoryWindowModel.Key? {
        // Shift, Option, Command or Control with Left or Right Arrow select text or move by word in the search field.
        let editingModifiers: EventModifiers = [.shift, .option, .command, .control]
        let isEditing = !press.modifiers.isDisjoint(with: editingModifiers)
        switch press.key {
        case .upArrow:
            return .up
        case .downArrow:
            return .down
        case .leftArrow:
            return isEditing ? nil : .left
        case .rightArrow:
            return isEditing ? nil : .right
        case .return:
            return .return
        case .escape:
            return .escape
        default:
            return nil
        }
    }

    /// True when the caret of the search field is after its last character with nothing selected, or the search
    /// field is not being edited. Only then does Right Arrow open the preview instead of moving the caret.
    @MainActor private static var isCaretAtEnd: Bool {
        guard let editor = NSApplication.shared.keyWindow?.firstResponder as? NSTextView else {
            return true
        }
        let selection = editor.selectedRange()
        return selection.length == 0 && selection.location >= (editor.string as NSString).length
    }

    /// True while the search field holds marked text: input that an input method has not committed yet.
    @MainActor private static var isComposingText: Bool {
        guard let editor = NSApplication.shared.keyWindow?.firstResponder as? NSTextView else {
            return false
        }
        return editor.hasMarkedText()
    }

    private func chooseSelected() {
        if let entry = model.selectedEntry {
            onChoose(entry)
        }
    }
}

private struct HistoryRow: View {
    let entry: ClipboardEntry
    let isRevealed: Bool
    let isSelected: Bool
    let now: Date
    let model: HistoryWindowModel
    let icons: any FileIconProviding

    var body: some View {
        HStack(spacing: 10) {
            switch entry.content {
            case .image(let image):
                EntryThumbnail(image: image, provider: model.thumbnails)
            case .files(let files):
                // The first file's thumbnail when it is a photo or video that has one, otherwise its icon.
                FileThumbnailIcon(
                    path: files.first?.path ?? "/", thumbnail: files.first?.thumbnail, size: 32,
                    provider: model.thumbnails, icons: icons)
            case .text, .richText:
                EmptyView()
            }
            details
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var details: some View {
        // A concealed entry shows a mask of fixed length until revealed. Revealed text is sanitized like any other.
        let preview = EntryPreview.rowText(for: entry, isRevealed: isRevealed)
        let appName = entry.sourceApp?.name.map { EntryPreview.text($0) } ?? ""
        return VStack(alignment: .leading, spacing: 3) {
            Group {
                if entry.isConcealed {
                    // VoiceOver never reads a password, revealed or not.
                    Text(verbatim: preview)
                        .fontDesign(.monospaced)
                        .accessibilityLabel(isRevealed ? Text("Password, shown") : Text("Password, hidden"))
                } else if preview.isEmpty {
                    Text("Blank text")
                        .italic()
                        .foregroundStyle(.secondary)
                } else {
                    switch entry.content {
                    case .text:
                        Text(verbatim: preview)
                    case .richText:
                        Text(verbatim: preview)
                            .accessibilityLabel(Text("Rich text, \(preview)"))
                    case .image:
                        // The format and pixel size, under the thumbnail's row.
                        Text(verbatim: preview)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Image, \(preview)"))
                    case .files(let files):
                        FileRowTitle(entryID: entry.id, files: files, names: preview, model: model)
                    }
                }
            }
            .lineLimit(EntryPreview.maximumLines)
            .truncationMode(.tail)
            HStack(spacing: 6) {
                if appName.isEmpty {
                    Text("Unknown app")
                } else {
                    Text(verbatim: appName)
                }
                Spacer(minLength: 8)
                Text(verbatim: EntryPreview.relativeTime(of: entry.date, now: now))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

/// Shows or hides the text of one concealed entry until the window closes.
private struct RevealButton: View {
    let isRevealed: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: isRevealed ? "eye.slash" : "eye")
        }
        .buttonStyle(.borderless)
        .help(isRevealed ? Text("Hide password") : Text("Show password"))
        .accessibilityLabel(isRevealed ? Text("Hide password") : Text("Show password"))
        .padding(.trailing, 10)
    }
}

/// Creates the AppKit view that hosts `HistoryView`, so the window controller does not depend on SwiftUI.
enum HistoryContentFactory {
    @MainActor
    static func makeView(
        model: HistoryWindowModel,
        onChoose: @escaping @MainActor (ClipboardEntry) -> Void,
        onClose: @escaping @MainActor () -> Void,
        onOpenSettings: @escaping @MainActor () -> Void
    ) -> NSView {
        let view = HistoryView(model: model, onChoose: onChoose, onClose: onClose, onOpenSettings: onOpenSettings)
        let hostingView = NSHostingView(rootView: view)
        // The panel sets the size, not the SwiftUI content: the window controller switches between the compact and
        // the full size, and the hosting view follows through its autoresizing mask.
        hostingView.sizingOptions = []
        // The hidden title bar would otherwise count as a top safe-area inset and push the search field down.
        hostingView.safeAreaRegions = []
        hostingView.frame = NSRect(origin: .zero, size: HistoryPanelPlacement.fullSize)
        return hostingView
    }
}
