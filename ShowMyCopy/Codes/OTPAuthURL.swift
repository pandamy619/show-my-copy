import Foundation

/// The `otpauth://totp/Label?secret=…` address a service shows when it is set up, as a QR code or as text
/// ("Can't scan? Enter this key"), in the form Google Authenticator defined.
enum OTPAuthURL {
    enum ParsingError: Error, Equatable, Sendable {
        /// Not an `otpauth:` address at all.
        case notAnOTPAuthURL
        /// `otpauth://hotp/…` or another type: only time-based codes are supported.
        case unsupportedType(String)
        case missingSecret
        case invalidSecret(Base32.DecodingError)
        case unsupportedAlgorithm(String)
        case unsupportedDigits(String)
        case invalidPeriod(String)
    }

    static let scheme = "otpauth"

    /// The account the address describes. The issuer comes from the `issuer` parameter, else from the label's
    /// "Issuer:" prefix. Unknown parameters are ignored, as the format asks.
    static func account(from text: String) throws(ParsingError) -> OneTimeCodeAccount {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed, encodingInvalidCharacters: true),
            components.scheme?.lowercased() == scheme
        else { throw .notAnOTPAuthURL }
        guard let type = components.host?.lowercased(), !type.isEmpty else { throw .notAnOTPAuthURL }
        guard type == "totp" else { throw .unsupportedType(type) }
        let parameters = Dictionary(
            (components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        let label = OneTimeCodeAccount.splitLabel(String(components.path.drop(while: { $0 == "/" })))
        let issuer = parameters["issuer"]?.trimmingCharacters(in: .whitespaces) ?? ""
        return OneTimeCodeAccount(
            issuer: issuer.isEmpty ? label.issuer : issuer,
            name: label.name,
            secret: try secret(from: parameters["secret"]),
            algorithm: try algorithm(from: parameters["algorithm"]),
            digits: try digits(from: parameters["digits"]),
            period: try period(from: parameters["period"])
        )
    }

    private static func secret(from text: String?) throws(ParsingError) -> Data {
        guard let text, !text.isEmpty else { throw .missingSecret }
        let secret: Data
        do {
            secret = try Base32.decode(text)
        } catch {
            throw .invalidSecret(error)
        }
        guard !secret.isEmpty else { throw .missingSecret }
        return secret
    }

    private static func algorithm(from text: String?) throws(ParsingError) -> OneTimeCodeAccount.Algorithm {
        guard let text, !text.isEmpty else { return .sha1 }
        let name = text.uppercased().replacingOccurrences(of: "-", with: "")
        guard let known = OneTimeCodeAccount.Algorithm(rawValue: name) else { throw .unsupportedAlgorithm(text) }
        return known
    }

    private static func digits(from text: String?) throws(ParsingError) -> OneTimeCodeAccount.Digits {
        guard let text, !text.isEmpty else { return .six }
        guard let count = Int(text), let known = OneTimeCodeAccount.Digits(rawValue: count) else {
            throw .unsupportedDigits(text)
        }
        return known
    }

    private static func period(from text: String?) throws(ParsingError) -> Int {
        guard let text, !text.isEmpty else { return OneTimeCodeAccount.defaultPeriod }
        guard let seconds = Int(text), seconds > 0 else { throw .invalidPeriod(text) }
        return seconds
    }
}
