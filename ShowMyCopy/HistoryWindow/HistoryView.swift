import AppKit
import SwiftUI

/// Search field and clipboard history list shown in the history panel.
struct HistoryView: View {
    @Bindable var model: HistoryWindowModel
    let onChoose: @MainActor (ClipboardEntry) -> Void
    let onClose: @MainActor () -> Void
    let onOpenSettings: @MainActor () -> Void

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let items = model.items
        let selectedID = model.selectedIndex(in: items).map { items[$0].id }
        VStack(spacing: 0) {
            searchBar
            Divider()
            if items.isEmpty {
                emptyState
            } else {
                list(items: items, selectedID: selectedID, now: Date())
            }
        }
        .frame(width: HistoryPanelPlacement.size.width, height: HistoryPanelPlacement.size.height)
        .defaultFocus($isSearchFocused, true)
        .onAppear { isSearchFocused = true }
        .onChange(of: model.presentationCount) { isSearchFocused = true }
        .onKeyPress(keys: Self.handledKeys) { handleKey($0.key) }
        .onExitCommand { onClose() }
    }

    private static let handledKeys: Set<KeyEquivalent> = [.upArrow, .downArrow, .return, .escape]

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isSearchFocused)
                .onKeyPress(keys: Self.handledKeys) { handleKey($0.key) }
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
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.history.entries.isEmpty {
            ContentUnavailableView(
                "Nothing copied yet",
                systemImage: "doc.on.clipboard",
                description: Text("Text you copy will appear here.")
            )
        } else {
            ContentUnavailableView("No matches", systemImage: "magnifyingglass")
        }
    }

    private func list(items: [ClipboardEntry], selectedID: ClipboardEntry.ID?, now: Date) -> some View {
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
        Button {
            onChoose(entry)
        } label: {
            HistoryRow(entry: entry, isSelected: entry.id == selectedID, now: now)
        }
        .buttonStyle(.plain)
        .id(entry.id)
    }

    private func handleKey(_ key: KeyEquivalent) -> KeyPress.Result {
        switch key {
        case .upArrow:
            model.moveSelection(.up)
        case .downArrow:
            model.moveSelection(.down)
        case .return:
            chooseSelected()
        case .escape:
            onClose()
        default:
            return .ignored
        }
        return .handled
    }

    private func chooseSelected() {
        if let entry = model.selectedEntry {
            onChoose(entry)
        }
    }
}

private struct HistoryRow: View {
    let entry: ClipboardEntry
    let isSelected: Bool
    let now: Date

    var body: some View {
        let preview = EntryPreview.text(entry.text)
        let appName = entry.sourceApp?.name.map { EntryPreview.text($0) } ?? ""
        VStack(alignment: .leading, spacing: 3) {
            Group {
                if preview.isEmpty {
                    Text("Blank text")
                        .italic()
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: preview)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: HistoryPanelPlacement.size)
        return hostingView
    }
}
