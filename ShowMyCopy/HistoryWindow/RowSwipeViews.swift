import AppKit
import SwiftUI

/// Swiping a history row: the row slides left over a button for each of its actions (`RowAction`), with a two-finger
/// swipe on a trackpad. `RowSwipe` decides everything; this only draws its state and feeds it events. A mouse drag
/// drags the entry out of the window instead (`RowDragSource`).
///
/// The buttons are hidden from VoiceOver: the row offers the same actions as accessibility actions, from the same
/// list.
struct RowSwipeModifier: ViewModifier {
    let entry: ClipboardEntry
    let model: HistoryWindowModel

    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        let swipe = model.swipe
        let offset = swipe.displayedOffset(of: entry.id, reducesMotion: reducesMotion)
        // The row follows the fingers as they move, and slides into place when they let go. Not with Reduce Motion:
        // then the buttons just appear.
        let animates = !reducesMotion && !swipe.isTracking(entry.id)
        content
            .offset(x: -offset)
            .background(alignment: .trailing) {
                if offset > 0 {
                    SwipeActionButtons(offers: RowAction.offers(for: entry), offset: offset) { action in
                        model.perform(action, on: entry)
                    }
                }
            }
            // Over the whole row, but only scroll events stop there: clicks reach the row and the buttons.
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

/// The buttons an open row shows at its trailing edge, in the order of `offers`, Delete last at the edge. They share
/// the width the row slid, so they grow with the swipe; past their full width only Delete grows, toward a full swipe.
private struct SwipeActionButtons: View {
    let offers: [RowAction.Offer]
    let offset: CGFloat
    let perform: @MainActor (RowAction) -> Void

    var body: some View {
        let count = CGFloat(max(offers.count, 1))
        let shared = min(offset, RowSwipe.actionsWidth(buttonCount: offers.count)) / count
        HStack(spacing: 0) {
            ForEach(offers, id: \.action) { offer in
                let isLast = offer.action == offers.last?.action
                SwipeActionButton(
                    offer: offer, width: isLast ? max(offset - shared * (count - 1), 0) : shared
                ) {
                    perform(offer.action)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SwipeActionButton: View {
    let offer: RowAction.Offer
    let width: CGFloat
    let action: @MainActor () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: offer.action.systemImage)
                    .imageScale(.medium)
                Text(offer.action.buttonTitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .frame(width: RowSwipe.buttonWidth)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(offer.isEnabled ? offer.action.swipeColor : Color.gray)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!offer.isEnabled)
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
