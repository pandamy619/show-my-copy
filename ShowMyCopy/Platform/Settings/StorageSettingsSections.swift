import AppKit
import SwiftUI

/// Settings → Storage: how much the history takes by type and on disk, the app's memory, the size limit and any
/// problem saving the history.
struct StorageSection: View {
    let settings: HistorySettings
    let usage: StorageUsage

    @State private var draftSizeLimit: HistorySizeLimit
    /// A smaller size limit the user picked that would delete entries. Applied only after they confirm.
    @State private var pendingSizeLimit: HistorySizeLimit?

    init(settings: HistorySettings, usage: StorageUsage) {
        self.settings = settings
        self.usage = usage
        _draftSizeLimit = State(initialValue: settings.sizeLimit)
    }

    var body: some View {
        Section("Storage") {
            let breakdown = usage.breakdown
            let warning = usage.storageWarning
            if let warning {
                // A problem saving never stops the app, so this is a note, not an alert.
                Label {
                    Text(Self.message(for: warning))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
            }
            LabeledContent("History size") {
                Text(verbatim: ByteCount.fileSize(breakdown.totalBytes))
                    .monospacedDigit()
            }
            if let diskBytes = usage.diskBytes {
                LabeledContent("On disk") {
                    Text(verbatim: ByteCount.fileSize(Int(clamping: diskBytes)))
                        .monospacedDigit()
                }
            }
            if let damagedBytes = usage.damagedHistoryBytes.map({ ByteCount.fileSize(Int(clamping: $0)) }) {
                // Counted in "On disk" above; this says what the part the history does not show is.
                VStack(alignment: .leading, spacing: 2) {
                    Text("A copy of a history that could not be opened takes \(damagedBytes).")
                    Text("It is deleted a week after it was set aside, or at once with Clear History.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !breakdown.parts.isEmpty {
                StorageBar(breakdown: breakdown)
            }
            LabeledContent("App memory") {
                if let bytes = usage.appMemoryBytes {
                    Text(verbatim: ByteCount.memorySize(bytes))
                        .monospacedDigit()
                } else {
                    Text("Not available")
                }
            }
            Picker("Size limit", selection: $draftSizeLimit) {
                ForEach(HistorySizeLimit.allCases) { limit in
                    Self.title(of: limit).tag(limit)
                }
            }
            // Attached to one row: modifiers on a Section can apply to each of its rows.
            .onChange(of: draftSizeLimit) { _, newValue in
                draftSizeLimitChanged(to: newValue)
            }
            .onChange(of: usage.history.revision) {
                // The history can change while a confirmation is shown. Re-check what the change would do.
                if let pendingSizeLimit {
                    draftSizeLimitChanged(to: pendingSizeLimit)
                }
            }
            if let pendingSizeLimit {
                let change = settings.proposeSizeLimit(pendingSizeLimit)
                InlineConfirmation(
                    message: .removingOldestItems(change.removedCount),
                    detail: .freeing(bytes: change.freedBytes),
                    confirmTitle: "Remove",
                    onConfirm: confirmPendingSizeLimit,
                    onCancel: cancelPendingSizeLimit
                )
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    sizeLimitNote
                    // Not true while the store on disk cannot be opened; the warning above says so then.
                    if warning != .notSaved {
                        Text("Saved on this Mac only. Not synced, not in Time Machine backups.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Plain words for each problem, without technical details: those are in the log.
    private static func message(for warning: StorageWarning) -> LocalizedStringKey {
        switch warning {
        case .notSaved:
            "History cannot be saved right now and will be lost when you quit."
        case .historyReset:
            "The saved history could not be read, so a new one was started."
        case .historyNotLoaded:
            "The saved history could not be loaded."
        case .changesNotSaved:
            "Recent changes could not be saved. They are kept until you quit."
        case .passwordsNotSaved:
            "Passwords could not be encrypted, so they are not saved on disk."
        }
    }

    /// What the chosen limit allows. Raising it never removes anything, so this is all it says.
    private var sizeLimitNote: Text {
        if let byteLimit = settings.sizeLimit.byteLimit {
            Text("History can use up to \(ByteCount.fileSize(byteLimit)).")
        } else {
            Text("Only the number of items limits the history.")
        }
    }

    private static func title(of limit: HistorySizeLimit) -> Text {
        if let byteLimit = limit.byteLimit {
            Text(verbatim: ByteCount.fileSize(byteLimit))
        } else {
            Text("No limit")
        }
    }

    private func draftSizeLimitChanged(to limit: HistorySizeLimit) {
        let change = settings.proposeSizeLimit(limit)
        if change.needsConfirmation {
            pendingSizeLimit = limit
        } else {
            pendingSizeLimit = nil
            if limit != settings.sizeLimit {
                settings.applySizeLimit(limit)
            }
        }
    }

    private func confirmPendingSizeLimit() {
        if let pendingSizeLimit {
            settings.applySizeLimit(pendingSizeLimit)
        }
        pendingSizeLimit = nil
        draftSizeLimit = settings.sizeLimit
    }

    private func cancelPendingSizeLimit() {
        pendingSizeLimit = nil
        draftSizeLimit = settings.sizeLimit
    }
}

/// Settings → Clear History, with what it frees before and after.
struct ClearHistorySection: View {
    let usage: StorageUsage

    @State private var isConfirmingClear = false

    var body: some View {
        Section {
            content
                .onChange(of: usage.history.revision) {
                    if usage.history.entries.isEmpty {
                        isConfirmingClear = false
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        let forecast = usage.clearForecast
        if isConfirmingClear {
            InlineConfirmation(
                // The catalog has plural variations, such as "This removes 1 item from your history." for one.
                message: Text("This removes all \(forecast.count) items from your history."),
                detail: .freeing(bytes: forecast.totalBytes),
                confirmTitle: "Remove All",
                onConfirm: {
                    usage.clearHistory()
                    isConfirmingClear = false
                },
                onCancel: { isConfirmingClear = false }
            )
        } else if let cleared = usage.recentClear {
            // A calm note in place of the button until something new is copied.
            Text("History cleared, \(ByteCount.fileSize(cleared.freedBytes)) freed.")
                .foregroundStyle(.secondary)
        } else {
            HStack {
                Button("Clear History…") {
                    isConfirmingClear = true
                }
                // Also with no entries, when only a damaged copy of a history is left to delete.
                .disabled(!usage.hasSomethingToClear)
                Spacer()
                if !usage.history.entries.isEmpty {
                    // Two texts, so the plural form depends on the count alone.
                    HStack(spacing: 0) {
                        Text("Removes \(forecast.count) items")
                        Text(verbatim: ", \(ByteCount.fileSize(forecast.totalBytes))")
                    }
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// The history's size as a bar split by type, with a legend. VoiceOver reads it as one element, such as
/// "History by type: Text 1.2 MB, Passwords 3 KB".
private struct StorageBar: View {
    let breakdown: StorageBreakdown

    private static let barHeight: CGFloat = 8
    private static let gap: CGFloat = 1
    /// A part of a few bytes next to megabytes of text still shows as a sliver.
    private static let minimumSegment: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let segments = zip(breakdown.parts, segmentWidths(in: proxy.size.width)).map { (part: $0, width: $1) }
                HStack(spacing: Self.gap) {
                    ForEach(segments, id: \.part.id) { segment in
                        Rectangle()
                            .fill(Self.color(of: segment.part.category))
                            .frame(width: segment.width)
                    }
                }
            }
            .frame(height: Self.barHeight)
            .clipShape(Capsule())
            // In one row while it fits; with many kinds of content (or long translations), one part per line.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    ForEach(breakdown.parts) { part in
                        legendItem(part)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(breakdown.parts) { part in
                        legendItem(part)
                    }
                }
            }
            .font(.caption)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("History by type"))
        .accessibilityValue(Text(verbatim: accessibilityValue))
    }

    private func legendItem(_ part: StorageBreakdown.Part) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Self.color(of: part.category))
                .frame(width: 8, height: 8)
            Text(Self.title(of: part.category))
            Text(verbatim: ByteCount.fileSize(part.bytes))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .fixedSize()
    }

    private var accessibilityValue: String {
        breakdown.parts
            .map { "\(String(localized: Self.title(of: $0.category))) \(ByteCount.fileSize($0.bytes))" }
            .joined(separator: ", ")
    }

    /// Each part's width by its share of the bytes, at least `minimumSegment`. The widest part gives up the room
    /// the small ones take, so the bar never grows past `total`.
    private func segmentWidths(in total: CGFloat) -> [CGFloat] {
        let available: CGFloat = max(total - Self.gap * CGFloat(max(breakdown.parts.count - 1, 0)), 0)
        var widths: [CGFloat] = breakdown.parts.map { part in
            max(available * CGFloat(breakdown.fraction(of: part)), Self.minimumSegment)
        }
        let excess = widths.reduce(0, +) - available
        if excess > 0, let widest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            widths[widest] = max(widths[widest] - excess, 0)
        }
        return widths
    }

    private static func title(of category: StorageCategory) -> LocalizedStringResource {
        switch category {
        case .text:
            "Text"
        case .richText:
            "Rich text"
        case .images:
            "Images"
        case .files:
            "Files"
        case .passwords:
            "Passwords"
        }
    }

    /// System colors, which adapt to light and dark mode and to Increase Contrast.
    private static func color(of category: StorageCategory) -> Color {
        switch category {
        case .text:
            Color(nsColor: .systemBlue)
        case .richText:
            Color(nsColor: .systemTeal)
        case .images:
            Color(nsColor: .systemPurple)
        case .files:
            Color(nsColor: .systemGreen)
        case .passwords:
            Color(nsColor: .systemOrange)
        }
    }
}
