import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center button that opens the clipboard history. It has no state to show, so the extension reads
/// nothing: the button only names `OpenHistoryIntent`, which the app performs.
struct HistoryControl: ControlWidget {
    static let kind = "com.pandamy619.ShowMyCopy.HistoryControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenHistoryIntent()) {
                Label("Clipboard History", systemImage: "doc.on.clipboard")
            }
        }
        .displayName("Clipboard History")
        .description("Opens the history of what you copied.")
    }
}
