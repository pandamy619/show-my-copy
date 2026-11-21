import Foundation

/// The accounts in `Application Support/ShowMyCopy/Codes/Accounts.sealed`: JSON, sealed with the same key as saved
/// passwords (`KeychainSecretSealer`), in a folder left out of backups. The whole file is written at once, atomically,
/// so a failed write leaves the previous accounts in place.
///
/// The key is the history key, so a user who allowed the app to use it for passwords is not asked again for codes,
/// and the file can be opened only by a build macOS lets read that Keychain item.
struct SealedCodeAccountsFile: CodeAccountsPersisting {
    static let folderName = "Codes"
    static let fileName = "Accounts.sealed"
    /// The format of the JSON inside; a newer app may change it, and this one then leaves the file alone.
    static let formatVersion = 1

    let directory: URL
    let sealer: any SecretSealing

    /// The app's own folder in Application Support, or nil when it cannot be found: then accounts are kept in
    /// memory for the session.
    static func openDefault(sealer: any SecretSealing) -> SealedCodeAccountsFile? {
        guard let applicationSupport = HistoryFolder.applicationSupport() else {
            return nil
        }
        let appFolder = HistoryFolder.appFolder(inApplicationSupport: applicationSupport)
        return SealedCodeAccountsFile(
            directory: appFolder.appending(path: folderName, directoryHint: .isDirectory), sealer: sealer)
    }

    var fileURL: URL {
        directory.appending(path: Self.fileName, directoryHint: .notDirectory)
    }

    func load() async -> CodeAccountsLoad {
        let path = fileURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            return .accounts([])
        }
        switch await sealer.loadKey() {
        case .ready:
            break
        case .lockedOut:
            return .keyLockedOut
        case .unavailable:
            return .keyUnavailable
        }
        guard let sealed = FileManager.default.contents(atPath: path) else {
            AppLogger.security.error("The saved code accounts could not be read")
            return .unreadable
        }
        let json: Data
        do {
            json = try sealer.open(sealed)
        } catch let error as SecretSealingError where error.isAboutTheKey {
            return error == .keyUnavailable(.interactionNotAllowed) ? .keyLockedOut : .keyUnavailable
        } catch {
            AppLogger.security.error("The saved code accounts could not be opened; they are left as they are")
            return .damaged
        }
        return Self.decode(json)
    }

    func save(_ accounts: [CodeAccount]) async throws(CodeAccountsSaveError) {
        let fileManager = FileManager.default
        if accounts.isEmpty {
            // Nothing to keep: no file, rather than a file that says so.
            do {
                if fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: fileURL)
                }
            } catch {
                AppLogger.security.error("The code accounts file could not be deleted")
                throw .writeFailed
            }
            return
        }
        // The first save makes the key, off the main actor; a locked Keychain is tried again at the next change.
        guard await sealer.loadKey() == .ready else {
            throw .keyNotReady
        }
        let sealed: Data
        do {
            sealed = try sealer.seal(try Self.encode(accounts))
        } catch let error as SecretSealingError where error.isAboutTheKey {
            throw .keyNotReady
        } catch {
            AppLogger.security.error("The code accounts could not be sealed")
            throw .sealingFailed
        }
        do {
            try Self.prepare(directory)
            try sealed.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            AppLogger.security.error("The code accounts could not be saved")
            throw .writeFailed
        }
    }

    /// Creates the folder and excludes it from backups, like the history's folder.
    private static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = directory
        try directory.setResourceValues(values)
    }

    // MARK: - Format

    private struct File: Codable {
        let version: Int
        let accounts: [Record]
    }

    private struct Record: Codable {
        let id: UUID
        let issuer: String
        let name: String
        /// Base64, as `Data` encodes itself.
        let secret: Data
        let algorithm: String
        let digits: Int
        let period: Int
        let addedAt: TimeInterval
    }

    static func encode(_ accounts: [CodeAccount]) throws -> Data {
        let records = accounts.map { stored in
            Record(
                id: stored.id, issuer: stored.account.issuer, name: stored.account.name, secret: stored.account.secret,
                algorithm: stored.account.algorithm.rawValue, digits: stored.account.digits.rawValue,
                period: stored.account.period, addedAt: stored.addedAt.timeIntervalSince1970)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(File(version: formatVersion, accounts: records))
    }

    /// The accounts in `json`. A file of a newer version, or one with a record this version cannot make an account
    /// of, is reported rather than read in part: a partial list saved back would lose the rest.
    static func decode(_ json: Data) -> CodeAccountsLoad {
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: json)
        } catch {
            return .damaged
        }
        guard file.version <= formatVersion else {
            return .newerFormat
        }
        var accounts: [CodeAccount] = []
        for record in file.accounts {
            guard !record.secret.isEmpty, record.period > 0,
                let algorithm = OneTimeCodeAccount.Algorithm(rawValue: record.algorithm),
                let digits = OneTimeCodeAccount.Digits(rawValue: record.digits)
            else {
                return .damaged
            }
            accounts.append(
                CodeAccount(
                    id: record.id,
                    account: OneTimeCodeAccount(
                        issuer: record.issuer, name: record.name, secret: record.secret, algorithm: algorithm,
                        digits: digits, period: record.period),
                    addedAt: Date(timeIntervalSince1970: record.addedAt)))
        }
        return .accounts(accounts)
    }
}
