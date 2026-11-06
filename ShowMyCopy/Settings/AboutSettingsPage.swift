import AppKit
import SwiftUI

/// Settings → About: the app's icon, name, version and license, where its source code is and the name of its
/// privacy policy there.
///
/// The app opens no links, so the address is text, not a link: it can be selected and copied, and the copy goes to
/// `copyText`, which puts it on the clipboard without recording it (`EntryCopying.copyText(_:)`), like a folder
/// copied from the history window's preview.
struct AboutSettingsPage: View {
    let copyText: @MainActor (String) -> Void

    /// Where the source code, the license and the privacy policy are.
    static let repository = "https://github.com/pandamy619/show-my-copy"

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                        .resizable()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    Text(verbatim: "Show My Copy")
                        .font(.title2.bold())
                    Text("Version \(Self.version)")
                        .foregroundStyle(.secondary)
                    Text("MIT License")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                LabeledContent("Source code") {
                    SelectablePathText(text: Self.repository, onCopy: copyText, onEscape: {})
                }
                LabeledContent("Privacy policy") {
                    Text("PRIVACY.md", comment: "The privacy policy's file name in the source code, in this language.")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The version people see, such as "0.1.0", from the app's Info.plist.
    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}
