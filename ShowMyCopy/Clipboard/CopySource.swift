/// Where a pasteboard change came from, as far as the monitor can tell, and what that means for reading it. Decided
/// from the app in front alone, before anything is read from the pasteboard, not even its types.
enum CopySource: Equatable, Sendable {
    /// No known app: the change was found on the first look after launch or a pause (the app in front now did not
    /// necessarily make it), or no app is in front. It is read and recorded, as before excluded apps existed: an
    /// excluded app cannot be recognized here, and skipping every such change would lose copies from other devices
    /// and from before launch. Only markers tell whether it is a password.
    case unknown
    /// An app the user excluded. Nothing is read and nothing is recorded.
    case excluded
    /// A known password manager (`PasswordManager`): what it copies is a password, also without a marker.
    case passwordManager(SourceApp)
    /// Any other app, also one without a bundle identifier, which can be neither excluded nor a password manager.
    case app(SourceApp)

    /// The user's exclusions go first: an excluded password manager is not read even while passwords are saved.
    @MainActor
    init(app: SourceApp?, isExcluded: @MainActor (String) -> Bool) {
        guard let app else {
            self = .unknown
            return
        }
        guard let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty else {
            self = .app(app)
            return
        }
        if isExcluded(bundleIdentifier) {
            self = .excluded
        } else if PasswordManager.isPasswordManager(bundleIdentifier: bundleIdentifier) {
            self = .passwordManager(app)
        } else {
            self = .app(app)
        }
    }

    /// The app recorded with the copy.
    var app: SourceApp? {
        switch self {
        case .unknown, .excluded:
            nil
        case .passwordManager(let app), .app(let app):
            app
        }
    }

    var isPasswordManager: Bool {
        if case .passwordManager = self {
            return true
        }
        return false
    }
}
