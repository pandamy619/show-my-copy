import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Excluded apps: the apps whose copies are never read or recorded, with their icons, a button to remove
/// each, a menu of the apps open now to add one quickly, and Choose an App… for any installed app (an open panel,
/// `ApplicationOpenPanel`).
struct ExcludedAppsSection: View {
    let apps: ExcludedApps

    /// The open apps that can be added. Read again when the list changes and when an app launches or quits while
    /// Settings is open.
    @State private var addable: [ExcludedApp] = []
    /// Why the app picked last was not added, until the next pick or the list changes.
    @State private var chooseNote: ChosenAppOutcome?

    var body: some View {
        Section("Excluded apps") {
            if apps.apps.isEmpty {
                Text("No apps are excluded.")
                    .foregroundStyle(.secondary)
            }
            ForEach(apps.apps) { app in
                ExcludedAppRow(app: app) {
                    apps.remove(app)
                }
            }
            HStack {
                addMenu
                chooseButton
            }
            if let chooseNote, let text = Self.note(for: chooseNote) {
                text
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing is read from the clipboard while one of these apps is in front.")
                // The built-in list (`PasswordManager`) is not shown here; this matches the rule in Passwords above.
                Text("Copies from known password managers are skipped unless Save passwords is on.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Attached to one row: modifiers on a Section can apply to each of its rows.
    private var addMenu: some View {
        Menu("Add an Open App") {
            if addable.isEmpty {
                Text("No other apps are open.")
            }
            ForEach(addable) { app in
                // The name is the app's own, shown as it is.
                Button(app.name) {
                    apps.add(app)
                }
            }
        }
        .fixedSize()
        .onAppear(perform: refreshAddable)
        .onChange(of: apps.apps) {
            refreshAddable()
            chooseNote = nil
        }
        .onReceive(Self.runningAppsChanged) { _ in
            refreshAddable()
        }
    }

    /// Any app, with an open panel. Disabled while the panel is open, so there is one at a time.
    private var chooseButton: some View {
        Button("Choose an App…") {
            chooseNote = nil
            Task {
                chooseNote = await apps.chooseApp()
            }
        }
        .fixedSize()
        .disabled(apps.isChoosing)
    }

    /// Why the chosen app was not added; nothing when it was.
    private static func note(for outcome: ChosenAppOutcome) -> Text? {
        switch outcome {
        case .added:
            nil
        case .alreadyExcluded(let app):
            Text("\(app.name) is excluded already.")
        case .noBundleIdentifier:
            Text("This app has no bundle identifier, so it cannot be excluded.")
        case .thisApp:
            Text("Show My Copy cannot be excluded.")
        }
    }

    private func refreshAddable() {
        addable = apps.addableApps()
    }

    /// Posted on the main thread when an app launches or quits. Made once, so the view does not subscribe again on
    /// every update.
    @MainActor private static let runningAppsChanged: AnyPublisher<Notification, Never> = {
        let center = NSWorkspace.shared.notificationCenter
        return center.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: center.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .eraseToAnyPublisher()
    }()
}

/// One excluded app: its icon, its name and a button that removes it.
private struct ExcludedAppRow: View {
    let app: ExcludedApp
    let onRemove: () -> Void

    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                } else {
                    Color.clear
                }
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
            Text(verbatim: app.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(action: onRemove) {
                Label("Remove \(app.name)", systemImage: "minus.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(Text("Remove \(app.name)"))
        }
        // Looked up after the row appears, not while the view is built.
        .task(id: app.id) {
            icon = ApplicationIcon.icon(forBundleIdentifier: app.bundleIdentifier)
        }
    }
}

/// The icon of an app known only by its bundle identifier. Launch Services knows where the app is; the workspace
/// draws its icon from the bundle's icon file only, as Finder does, and only when the app is on the startup disk
/// (`CopiedPaths`): an app on another disk or a network volume gets the generic app icon, and its path is not touched.
/// An app that is no longer installed gets the generic icon too and stays in the list.
enum ApplicationIcon {
    @MainActor
    static func icon(forBundleIdentifier bundleIdentifier: String, paths: CopiedPaths = CopiedPaths()) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
            paths.access(for: url) == .startupDisk
        else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        return NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
    }
}
