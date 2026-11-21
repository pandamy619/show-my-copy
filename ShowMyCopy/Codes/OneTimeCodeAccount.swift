import Foundation

/// One account in an authenticator: whose code it is and how the code is computed. The same account is set up on the
/// phone and here, so both show the same code at the same time.
///
/// Only time-based codes (TOTP, RFC 6238), which is what Google Authenticator and almost every service use.
/// Counter-based codes (HOTP) would go out of step between the phone and the Mac, so they are not imported.
struct OneTimeCodeAccount: Equatable, Hashable, Sendable {
    enum Algorithm: String, CaseIterable, Sendable {
        case sha1 = "SHA1"
        case sha256 = "SHA256"
        case sha512 = "SHA512"
    }

    enum Digits: Int, CaseIterable, Sendable {
        case six = 6
        case eight = 8
    }

    /// The service, for example "GitHub". Empty when the account did not say.
    let issuer: String
    /// The account at the service, usually an e-mail address or user name. Empty when the account did not say.
    let name: String
    /// The shared secret, raw bytes. Never shown, logged or put in search.
    let secret: Data
    let algorithm: Algorithm
    let digits: Digits
    /// How long one code is valid, in seconds. 30 everywhere in practice.
    let period: Int

    static let defaultPeriod = 30

    /// What the entry is called in a list: "Issuer (name)", or whichever of them is known.
    var displayName: String {
        switch (issuer.isEmpty, name.isEmpty) {
        case (false, false):
            "\(issuer) (\(name))"
        case (false, true):
            issuer
        case (true, false):
            name
        case (true, true):
            ""
        }
    }

    /// Splits a label like "Example:alice@google.com" into the issuer and the name, as the `otpauth` format
    /// defines. Without a colon the whole label is the name. Surrounding spaces are removed.
    static func splitLabel(_ label: String) -> (issuer: String, name: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else { return ("", trimmed) }
        let issuer = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
        let name = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (issuer, name)
    }
}
