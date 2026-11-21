import Foundation

/// What Google Authenticator shows under Transfer accounts → Export accounts: a QR code of an
/// `otpauth-migration://offline?data=…` address whose `data` is a base64 protocol buffers message with every account.
/// Many accounts go in several QR codes, each one batch of the same export.
///
/// The message (from the app, not published by Google):
/// ```
/// MigrationPayload { repeated OtpParameters otp_parameters = 1; int32 version = 2; int32 batch_size = 3;
///                    int32 batch_index = 4; int32 batch_id = 5; }
/// OtpParameters { bytes secret = 1; string name = 2; string issuer = 3; Algorithm algorithm = 4;
///                 DigitCount digits = 5; OtpType type = 6; int64 counter = 7; }
/// Algorithm { UNSPECIFIED = 0; SHA1 = 1; SHA256 = 2; SHA512 = 3; MD5 = 4; }
/// DigitCount { UNSPECIFIED = 0; SIX = 1; EIGHT = 2; }   OtpType { UNSPECIFIED = 0; HOTP = 1; TOTP = 2; }
/// ```
struct AuthenticatorExport: Equatable, Sendable {
    enum DecodingError: Error, Equatable, Sendable {
        /// Not an `otpauth-migration:` address.
        case notAnExportURL
        case missingData
        /// `data` is not base64.
        case invalidData
        case malformed(ProtobufReader.DecodingError)
    }

    static let scheme = "otpauth-migration"

    let accounts: [OneTimeCodeAccount]
    /// Accounts in the export that cannot be imported, so the user can be told which ones.
    let skipped: [SkippedAccount]
    /// Which QR code of the export this is, from 0, and how many there are; 0 of 1 for a single code.
    let batchIndex: Int
    let batchSize: Int

    static func decode(_ text: String) throws(DecodingError) -> AuthenticatorExport {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed, encodingInvalidCharacters: true),
            components.scheme?.lowercased() == scheme
        else { throw .notAnExportURL }
        guard let encoded = components.queryItems?.first(where: { $0.name == "data" })?.value, !encoded.isEmpty
        else { throw .missingData }
        guard let payload = base64Data(encoded) else { throw .invalidData }
        do {
            return try decode(payload: payload)
        } catch {
            throw .malformed(error)
        }
    }

    /// Base64 with the padding some QR readers drop and the spaces some add.
    private static func base64Data(_ text: String) -> Data? {
        var compact = text.filter { !$0.isWhitespace }
        // URL-safe base64, in case the address was rewritten on the way.
        compact = compact.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let missing = (4 - compact.count % 4) % 4
        compact += String(repeating: "=", count: missing)
        return Data(base64Encoded: compact)
    }

    static func decode(payload: Data) throws(ProtobufReader.DecodingError) -> AuthenticatorExport {
        var accounts: [OneTimeCodeAccount] = []
        var skipped: [SkippedAccount] = []
        var batchIndex = 0
        var batchSize = 1
        var reader = ProtobufReader(payload)
        while let field = try reader.next() {
            switch (field.number, field.value) {
            case (1, .bytes(let message)):
                switch try ExportedParameters(message).account() {
                case .success(let account):
                    accounts.append(account)
                case .failure(let entry):
                    skipped.append(entry)
                }
            case (3, .varint(let value)):
                batchSize = Int(clamping: value)
            case (4, .varint(let value)):
                batchIndex = Int(clamping: value)
            default:
                continue  // version, batch id, anything newer
            }
        }
        return AuthenticatorExport(
            accounts: accounts, skipped: skipped, batchIndex: batchIndex, batchSize: max(batchSize, 1)
        )
    }
}

/// An account in an export that cannot be imported.
struct SkippedAccount: Error, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// Counter-based (HOTP): the phone and the Mac would go out of step.
        case counterBased
        /// MD5 or a value this app does not know.
        case unsupportedAlgorithm
        case unsupportedDigits
        case emptySecret
    }

    let issuer: String
    let name: String
    let reason: Reason
}

/// One `OtpParameters` message as exported, before it is checked.
private struct ExportedParameters {
    private static let totp: UInt64 = 2
    private static let unspecified: UInt64 = 0

    var secret = Data()
    var name = ""
    var issuer = ""
    var algorithm: UInt64 = 0
    var digits: UInt64 = 0
    var type: UInt64 = 0

    init(_ message: Data) throws(ProtobufReader.DecodingError) {
        var reader = ProtobufReader(message)
        while let field = try reader.next() {
            switch (field.number, field.value) {
            case (1, .bytes(let value)):
                secret = value
            case (2, .bytes(let value)):
                name = String(bytes: value, encoding: .utf8) ?? ""
            case (3, .bytes(let value)):
                issuer = String(bytes: value, encoding: .utf8) ?? ""
            case (4, .varint(let value)):
                algorithm = value
            case (5, .varint(let value)):
                digits = value
            case (6, .varint(let value)):
                type = value
            default:
                continue  // counter, anything newer
            }
        }
        splitIssuerFromName()
    }

    /// Google writes the issuer both in its field and as the "Issuer:" prefix of the name; keep it once.
    private mutating func splitIssuerFromName() {
        let label = OneTimeCodeAccount.splitLabel(name)
        if issuer.isEmpty {
            issuer = label.issuer
            name = label.name
        } else if label.issuer == issuer {
            name = label.name
        } else {
            name = name.trimmingCharacters(in: .whitespaces)
        }
    }

    func account() -> Result<OneTimeCodeAccount, SkippedAccount> {
        guard type == Self.unspecified || type == Self.totp else { return .failure(skipped(.counterBased)) }
        guard !secret.isEmpty else { return .failure(skipped(.emptySecret)) }
        guard let knownAlgorithm else { return .failure(skipped(.unsupportedAlgorithm)) }
        guard let knownDigits else { return .failure(skipped(.unsupportedDigits)) }
        return .success(
            OneTimeCodeAccount(
                issuer: issuer, name: name, secret: secret, algorithm: knownAlgorithm, digits: knownDigits,
                period: OneTimeCodeAccount.defaultPeriod
            )
        )
    }

    private var knownAlgorithm: OneTimeCodeAccount.Algorithm? {
        switch algorithm {
        case 0, 1: .sha1
        case 2: .sha256
        case 3: .sha512
        default: nil
        }
    }

    private var knownDigits: OneTimeCodeAccount.Digits? {
        switch digits {
        case 0, 1: .six
        case 2: .eight
        default: nil
        }
    }

    private func skipped(_ reason: SkippedAccount.Reason) -> SkippedAccount {
        SkippedAccount(issuer: issuer, name: name, reason: reason)
    }
}
