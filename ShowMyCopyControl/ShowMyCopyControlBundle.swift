import SwiftUI
import WidgetKit

/// The Control Center extension: one button, no widgets.
@main
struct ShowMyCopyControlBundle: WidgetBundle {
    var body: some Widget {
        HistoryControl()
    }
}
