import AppKit
import SwiftUI

/// Search field and clipboard history list shown in the history panel.
struct HistoryView: View {
    @Bindable var model: HistoryWindowModel
    /// Copies the entry, and pastes it into the app in front when the flag is true.
    let onChoose: @MainActor (ClipboardEntry, Bool) -> Void
    /// Copies the account's code, and pastes it when the flag is true.
    let onChooseCode: @MainActor (CodeAccount, Bool) -> Void
    let onClose: @MainActor () -> Void
    let onOpenSettings: @MainActor (SettingsSection?) -> Void
    /// A row is being dragged into another app (`RowDragSource`).
    let onDrag: @MainActor (RowDragEvent) -> Void
    /// Copies text the user selected in the preview, such as a file's folder, without recording it.
    let onCopyText: @MainActor (String) -> Void

    @FocusState private var isSearchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    private let icons = WorkspaceFileIconProvider()

    var body: some View {
        let sections = model.sections
        let codes = model.codeRows
        let selectedID = model.selectedRowID
        VStack(spacing: 0) {
            searchBar
            Divider()
            if sections.isEmpty && codes.isEmpty {
                // The window controller shrinks the panel to exactly these rows.
                emptyState
            } else {
                // Only above a list: the compact panel is exactly as tall as its message row.
                HistoryNotices(model: model, onOpenSettings: onOpenSettings)
                let previewed = model.previewedEntry
                // The list stays underneath the preview, so it keeps its scroll position.
                list(sections: sections, codes: codes, selectedID: selectedID, now: Date())
                    .opacity(previewed == nil ? 1 : 0)
                    .allowsHitTesting(previewed == nil)
                    .accessibilityHidden(previewed != nil)
                    .overlay {
                        if let previewed {
                            EntryPreviewPane(
                                entry: previewed, preview: model.preview, thumbnails: model.thumbnails, icons: icons,
                                onCopyText: onCopyText,
                                onLeaveText: { isSearchFocused = true },
                                onClose: { model.preview.close() }
                            )
                        }
                    }
                    // An image saved or thumbnails made after the preview opened show up in it.
                    .onChange(of: previewed?.content) {
                        model.previewedEntryChanged()
                    }
                    // A folder selected in the preview had the focus; the keys go to the search field again.
                    .onChange(of: previewed == nil) { _, isClosed in
                        if isClosed {
                            isSearchFocused = true
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
        // Focus stays in the search field, so VoiceOver is told the notice instead of being moved to it.
        .onChange(of: model.pinLimitNoticeCount) { PinLimitNoticeRow.announce() }
        .onKeyPress(keys: Self.handledKeys) { handleKey($0) }
        .onExitCommand { onClose() }
    }

    static let handledKeys: Set<KeyEquivalent> = [
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
            if model.hasCodes {
                codesButton
            }
            Button {
                onOpenSettings(nil)
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

    /// Shows or hides the Codes section. Only with accounts to show; hidden each time the window opens. The section
    /// slides in under the search bar and out again; with Reduce Motion it just appears.
    private var codesButton: some View {
        Button {
            withAnimation(reducesMotion ? nil : .snappy(duration: 0.25)) {
                model.toggleCodes()
            }
        } label: {
            Image(systemName: model.showsCodes ? "123.rectangle.fill" : "123.rectangle")
                .imageScale(.large)
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("k", modifiers: .command)
        .help(model.showsCodes ? Text("Hide codes (⌘K)") : Text("Show codes (⌘K)"))
        .accessibilityLabel(model.showsCodes ? Text("Hide codes") : Text("Show codes"))
    }

    /// One slim row under the search bar, like Spotlight with no results.
    private var emptyState: some View {
        let isHistoryEmpty = model.history.entries.isEmpty && model.query.isEmpty
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

    private func list(
        sections: HistorySections, codes: [CodeAccount], selectedID: UUID?, now: Date
    ) -> some View {
        // After a skipped copy (a password, an image) nothing in the history is on the clipboard, and a pinned entry
        // on the clipboard stays among the pinned ones: then there is no "Current clipboard" row.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !codes.isEmpty {
                        codesSection(codes, selectedID: selectedID, aboveEntries: !sections.isEmpty)
                    }
                    if let current = sections.current {
                        sectionHeader("Current clipboard")
                        row(current, selectedID: selectedID, now: now)
                        Divider()
                            .padding(.vertical, 4)
                    }
                    if !sections.pinned.isEmpty {
                        sectionHeader("Pinned")
                        ForEach(sections.pinned) { entry in
                            row(entry, selectedID: selectedID, now: now)
                        }
                        if !sections.history.isEmpty {
                            Divider()
                                .padding(.vertical, 4)
                        }
                    }
                    if !sections.history.isEmpty {
                        sectionHeader("History")
                        ForEach(sections.history) { entry in
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
                if let first = model.rows.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
    }

    /// The Codes section, first under the search bar, when the user asked for it; it slides in and out.
    private func codesSection(_ codes: [CodeAccount], selectedID: UUID?, aboveEntries: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Codes")
            CodeRows(accounts: codes, selectedID: selectedID, model: model) { account, isAlternate in
                codeRowClicked(account, isAlternate: isAlternate)
            }
            if aboveEntries {
                Divider()
                    .padding(.vertical, 4)
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
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

    private func row(_ entry: ClipboardEntry, selectedID: UUID?, now: Date) -> some View {
        let isSelected = entry.id == selectedID
        let isRevealed = model.isRevealed(entry.id)
        // The eye button sits next to the row's button, not inside it: a button inside another button's label
        // would also choose the entry.
        return HStack(spacing: 0) {
            Button {
                rowClicked(entry, isAlternate: NSEvent.modifierFlags.contains(.option))
            } label: {
                HistoryRow(
                    entry: entry, isRevealed: isRevealed, isSelected: isSelected, now: now, model: model, icons: icons)
            }
            .buttonStyle(.plain)
            // Dragging the row with the mouse drags its entry into another app.
            .modifier(
                RowDragModifier(entry: entry, model: model, onDrag: onDrag) { isAlternate in
                    rowClicked(entry, isAlternate: isAlternate)
                }
            )
            .modifier(RowContextMenu(entry: entry, model: model))
            .modifier(PreviewAccessibilityHint(entry: entry))
            .modifier(RowActionsAccessibility(entry: entry, model: model))
            if entry.isConcealed {
                RevealButton(isRevealed: isRevealed) {
                    guard !model.closeSwipedRow() else {
                        return
                    }
                    model.toggleReveal(entry.id)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        // Swipe left to show the row's actions; the selection slides with the row.
        .modifier(RowSwipeModifier(entry: entry, model: model))
        .id(entry.id)
    }

    /// A click on the row of `entry` chooses it. ⌥-click (`isAlternate`) does the other of what Return does, like
    /// ⌥Return. While a row is swiped open, a click on any row only closes it, as in Mail.
    private func rowClicked(_ entry: ClipboardEntry, isAlternate: Bool) {
        guard !model.closeSwipedRow() else {
            return
        }
        onChoose(entry, model.choosingPastes(isAlternate: isAlternate))
    }

    /// A click on the row of an account copies its code, like Return on it.
    private func codeRowClicked(_ account: CodeAccount, isAlternate: Bool) {
        guard !model.closeSwipedRow() else {
            return
        }
        onChooseCode(account, model.choosingPastes(isAlternate: isAlternate))
    }

}

private struct HistoryRow: View {
    let entry: ClipboardEntry
    let isRevealed: Bool
    let isSelected: Bool
    let now: Date
    let model: HistoryWindowModel
    let icons: WorkspaceFileIconProvider

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
        // Where the copied files are, on hover. The row itself stays as it is.
        .modifier(FilePathsHelp(entry: entry))
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
                if entry.isPinned {
                    // A pinned entry's date is when it was pinned, which says little: the mark says more.
                    Image(systemName: "pin.fill")
                        .accessibilityLabel(Text("Pinned entry"))
                } else {
                    Text(verbatim: EntryPreview.relativeTime(of: entry.date, now: now))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}
