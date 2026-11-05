import AppKit
import SwiftUI

/// Swipe to delete on a history row: the row slides left over a red Delete button with a two-finger swipe on a
/// trackpad. `RowSwipe` decides everything; this only draws its state and feeds it events. A mouse drag drags the
/// entry out of the window instead (`RowDragSource`).
///
/// The Delete button is hidden from VoiceOver: the row already offers the same Delete as an action.
struct RowSwipeModifier: ViewModifier {
    let entry: ClipboardEntry
    let model: HistoryWindowModel

    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        let swipe = model.swipe
        let offset = swipe.displayedOffset(of: entry.id, reducesMotion: reducesMotion)
        // The row follows the fingers as they move, and slides into place when they let go. Not with Reduce Motion.
        let animates = !reducesMotion && !swipe.isTracking(entry.id)
        content
            .offset(x: -offset)
            .background(alignment: .trailing) {
                if offset > 0 {
                    DeleteSwipeButton(width: offset) {
                        model.delete(entry)
                    }
                }
            }
            // Over the whole row, but only scroll events stop there: clicks reach the row and the button.
            .overlay {
                RowSwipeScrollReader { scroll in
                    model.swipeScrolled(scroll, on: entry)
                }
                .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .animation(animates ? .snappy(duration: 0.2) : nil, value: offset)
    }
}

/// The red button an open row shows at its trailing edge. As wide as the row slid, so it grows with the swipe.
private struct DeleteSwipeButton: View {
    let width: CGFloat
    let action: @MainActor () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            Text("Delete")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .background(Color.red)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }
}

/// A transparent view over a row that receives the row's scroll events, and no other events.
private struct RowSwipeScrollReader: NSViewRepresentable {
    /// Returns whether the row took the event; the list scrolls with any other.
    let onScroll: @MainActor (RowSwipe.Scroll) -> Bool

    func makeNSView(context: Context) -> RowSwipeScrollView {
        let view = RowSwipeScrollView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: RowSwipeScrollView, context: Context) {
        view.onScroll = onScroll
    }
}

/// Takes the scroll events over a row and hands the row's own on: a horizontal trackpad swipe to the row, anything
/// else up the responder chain to the list's scroll view, as if this view were not there.
private final class RowSwipeScrollView: NSView {
    var onScroll: (@MainActor (RowSwipe.Scroll) -> Bool)?

    /// Only a scroll event finds this view. Clicks, the context menu and the pointer go to the row underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApplication.shared.currentEvent?.type == .scrollWheel else {
            return nil
        }
        return super.hitTest(point)
    }

    override func scrollWheel(with event: NSEvent) {
        if onScroll?(Self.scroll(from: event)) != true {
            super.scrollWheel(with: event)
        }
    }

    /// The event's phase and the fingers' movement. With natural scrolling the deltas follow the fingers; without
    /// it they are the other way round.
    private static func scroll(from event: NSEvent) -> RowSwipe.Scroll {
        let towardFingers: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        return RowSwipe.Scroll(
            phase: phase(of: event.phase),
            isMomentum: !event.momentumPhase.isEmpty,
            deltaX: event.scrollingDeltaX * towardFingers,
            deltaY: event.scrollingDeltaY * towardFingers)
    }

    private static func phase(of phase: NSEvent.Phase) -> RowSwipe.Phase {
        if phase.contains(.began) {
            return .began
        }
        if phase.contains(.changed) || phase.contains(.stationary) {
            return .changed
        }
        if phase.contains(.ended) {
            return .ended
        }
        if phase.contains(.cancelled) {
            return .cancelled
        }
        if phase.contains(.mayBegin) {
            return .mayBegin
        }
        return .none
    }
}
