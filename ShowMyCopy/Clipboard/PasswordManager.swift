import Foundation

/// Password managers known by bundle identifier.
///
/// Some password managers and browser extensions copy passwords without a pasteboard marker. Anything copied while
/// one of these apps is in front is treated as a password, like an item with `PasteboardMarker.concealed`.
/// The check needs a known source app, so it does not apply to a change found on the first poll after launch or a
/// pause; markers still apply there.
///
/// Bundle identifiers are compared without regard to letter case. Keep this the only list of password managers.
enum PasswordManager {
    /// Exact bundle identifiers, in lower case.
    static let bundleIdentifiers: Set<String> = [
        // 1Password 8, 1Password 7 and the older 1Password from outside the Mac App Store.
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        // Bitwarden.
        "com.bitwarden.desktop",
        // Passwords (macOS 15) and Keychain Access.
        "com.apple.passwords",
        "com.apple.keychainaccess",
        // KeePassXC.
        "org.keepassxc.keepassxc",
        // Proton Pass. Seen in a third-party app catalog only; to verify on a Mac.
        "me.proton.pass.electron",
        // Keeper. Seen in a third-party app catalog only; to verify on a Mac.
        "com.keepersecurity.passwordmanager",
    ]

    /// Vendors that ship several apps or editions. An identifier matches when it equals a prefix or continues it
    /// after a dot, so "com.lastpass" matches "com.lastpass.LastPass" but not "com.lastpassword".
    static let bundleIdentifierPrefixes: [String] = [
        // Strongbox from the Mac App Store ("com.markmcguill.strongbox.mac") and Strongbox Pro (".mac.pro").
        // The Pro identifier is confirmed by a third-party catalog; to verify on a Mac.
        "com.markmcguill.strongbox.mac",
        // LastPass: "com.lastpass.LastPass" (Mac App Store) and "com.lastpass.lastpassmacdesktop" (newer app).
        // Seen in third-party catalogs; to verify on a Mac.
        "com.lastpass",
        // Enpass: "in.sinew.Enpass-Desktop" and "in.sinew.Enpass-Desktop.App". To verify on a Mac.
        "in.sinew.enpass-desktop",
    ]

    // Not listed yet, to verify on a Mac: Dashlane (its Mac app is the iPad app), NordPass. Add their bundle
    // identifiers only after reading them from the installed app's Info.plist.

    static func isPasswordManager(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier = bundleIdentifier?.lowercased(), !bundleIdentifier.isEmpty else {
            return false
        }
        if bundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        return bundleIdentifierPrefixes.contains { prefix in
            let prefix = prefix.lowercased()
            return bundleIdentifier == prefix || bundleIdentifier.hasPrefix(prefix + ".")
        }
    }
}
