import Foundation

/// Accounts from text the user pasted or a QR code held: one or more `otpauth://` addresses, a Google Authenticator
/// export, or a bare key with the issuer and name typed next to it.
enum CodeImport {
    struct Outcome: Equatable, Sendable {
        var accounts: [OneTimeCodeAccount]
        /// Accounts an export holds that cannot be imported.
        var skipped: [SkippedAccount]
        /// For an export in several QR codes: which one this was, from 0, and how many there are.
        var batchIndex: Int?
        var batchSize: Int?

        static let nothing = Outcome(accounts: [], skipped: [])

        init(accounts: [OneTimeCodeAccount], skipped: [SkippedAccount], batchIndex: Int? = nil, batchSize: Int? = nil) {
            self.accounts = accounts
            self.skipped = skipped
            self.batchIndex = batchIndex
            self.batchSize = batchSize
        }

        mutating func merge(_ other: Outcome) {
            accounts += other.accounts
            skipped += other.skipped
            batchIndex = other.batchIndex ?? batchIndex
            batchSize = other.batchSize ?? batchSize
        }
    }

    enum Failure: Error, Equatable, Sendable {
        case empty
        case export(AuthenticatorExport.DecodingError)
        case address(OTPAuthURL.ParsingError)
        case key(Base32.DecodingError)
        /// A bare key needs at least an issuer or a name, so the account can be told apart in the list.
        case keyNeedsName
    }

    /// Parses `text`. Each non-empty line that is an `otpauth` or `otpauth-migration` address is one account or
    /// export; otherwise the whole text is a key, for the account named `issuer` and `name`.
    static func parse(_ text: String, issuer: String = "", name: String = "") throws(Failure) -> Outcome {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            throw .empty
        }
        if lines.allSatisfy(isAddress) {
            var outcome = Outcome.nothing
            for line in lines {
                outcome.merge(try parseAddress(line))
            }
            return outcome
        }
        return try parseKey(lines.joined(), issuer: issuer, name: name)
    }

    /// Whether the text is an address this import reads, by its scheme.
    static func isAddress(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.hasPrefix(AuthenticatorExport.scheme + ":") || lowered.hasPrefix(OTPAuthURL.scheme + ":")
    }

    private static func parseAddress(_ line: String) throws(Failure) -> Outcome {
        if line.lowercased().hasPrefix(AuthenticatorExport.scheme + ":") {
            do {
                let export = try AuthenticatorExport.decode(line)
                return Outcome(
                    accounts: export.accounts, skipped: export.skipped, batchIndex: export.batchIndex,
                    batchSize: export.batchSize)
            } catch {
                throw .export(error)
            }
        }
        do {
            return Outcome(accounts: [try OTPAuthURL.account(from: line)], skipped: [])
        } catch {
            throw .address(error)
        }
    }

    private static func parseKey(_ text: String, issuer: String, name: String) throws(Failure) -> Outcome {
        let issuer = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret: Data
        do {
            secret = try Base32.decode(text)
        } catch {
            throw .key(error)
        }
        guard !secret.isEmpty else {
            throw .empty
        }
        guard !issuer.isEmpty || !name.isEmpty else {
            throw .keyNeedsName
        }
        let account = OneTimeCodeAccount(
            issuer: issuer, name: name, secret: secret, algorithm: .sha1, digits: .six,
            period: OneTimeCodeAccount.defaultPeriod)
        return Outcome(accounts: [account], skipped: [])
    }
}
