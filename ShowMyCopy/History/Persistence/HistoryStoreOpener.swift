import Foundation
import os

/// The history to use, what went wrong opening the store on disk, if anything, and the files of a saved history
/// this session does not use.
struct OpenedHistory {
    let persistence: any HistoryPersistence
    let error: HistoryPersistenceError?
    /// Nil when there is no folder for the history at all.
    let leftovers: (any HistoryLeftovers)?
}

/// Opens `History.store` in `directory`, and decides what happens when it cannot be opened.
///
/// A store that does not open is not always damaged: another build of the app, a full disk, missing permissions or
/// a second running copy of the app can stop it from opening for a while. So it is first tried again, and while
/// it is a SQLite database it is left where it is and the history is kept in memory for this launch
/// (`openFailed`). It is moved aside to `History.store.damaged` (`storeReset`), and a new store started, only when
///
/// - the file is not a SQLite database at all, so no build can open it, or
/// - it failed to open on `failedLaunchesBeforeReset` launches in a row; one launch that opens it starts the count
///   again. Without this, a database that is damaged inside would keep the history in memory for good.
///
/// Only the latest damaged copy is kept.
@MainActor
struct HistoryStoreOpener {
    /// How often the store is tried within one launch. The tries follow each other at once: waiting would hold up
    /// the launch, and the next launch is the real second chance.
    static let attemptsPerLaunch = 3
    static let failedLaunchesBeforeReset = 3
    /// Where the count of launches in a row that could not open the store is kept. A count, not history data.
    static let failedLaunchesKey = "history.failedOpenLaunches"
    static let storeFileName = "History.store"
    /// Where a store that could not be opened is moved. Only the latest one is kept.
    static let damagedStoreFileName = "History.store.damaged"

    let directory: URL
    let defaults: UserDefaults
    /// Opens the store at the URL, creating it when there is none.
    let openStore: (URL) throws(HistoryPersistenceError) -> any HistoryPersistence

    var storeURL: URL {
        directory.appending(path: Self.storeFileName, directoryHint: .notDirectory)
    }

    var damagedStoreURL: URL {
        directory.appending(path: Self.damagedStoreFileName, directoryHint: .notDirectory)
    }

    func open() -> OpenedHistory {
        if let persistence = tryOpening() {
            defaults.removeObject(forKey: Self.failedLaunchesKey)
            return opened(persistence, error: nil)
        }
        switch StoreFileCheck.check(storeURL) {
        case .notADatabase:
            AppLogger.history.error("The history store is not a database; moving it aside")
            return reset()
        case .database:
            let failedLaunches = defaults.integer(forKey: Self.failedLaunchesKey) + 1
            guard failedLaunches < Self.failedLaunchesBeforeReset else {
                AppLogger.history.error("The history store failed to open on several launches; moving it aside")
                return reset()
            }
            defaults.set(failedLaunches, forKey: Self.failedLaunchesKey)
            AppLogger.history.error("Could not open the history store; leaving it as it is for this launch")
            return inMemory()
        case .missing, .unreadable:
            AppLogger.history.error("Could not open or create the history store; keeping the history in memory only")
            return inMemory()
        }
    }

    private func tryOpening() -> (any HistoryPersistence)? {
        for attempt in 1...Self.attemptsPerLaunch {
            do {
                return try openStore(storeURL)
            } catch {
                // What failed is logged where the store is opened.
                AppLogger.history.error("Opening the history store failed, attempt \(attempt, privacy: .public)")
            }
        }
        return nil
    }

    private func reset() -> OpenedHistory {
        defaults.removeObject(forKey: Self.failedLaunchesKey)
        do {
            try moveAside()
        } catch {
            AppLogger.history.error("Could not move the history store aside; keeping the history in memory only")
            return inMemory()
        }
        do {
            return opened(try openStore(storeURL), error: .storeReset)
        } catch {
            AppLogger.history.error("Could not start a new history store; keeping the history in memory only")
            return inMemory()
        }
    }

    /// Moves the store and its SQLite side files to `damagedStoreFileName`, replacing an older damaged copy.
    private func moveAside() throws {
        let fileManager = FileManager.default
        let moves = zip(StoreFiles.urls(forStoreAt: storeURL), StoreFiles.urls(forStoreAt: damagedStoreURL))
        for (source, destination) in moves {
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try fileManager.removeItem(at: destination)
            }
            if fileManager.fileExists(atPath: source.path(percentEncoded: false)) {
                try fileManager.moveItem(at: source, to: destination)
            }
        }
    }

    private func opened(_ persistence: any HistoryPersistence, error: HistoryPersistenceError?) -> OpenedHistory {
        OpenedHistory(
            persistence: persistence, error: error, leftovers: LeftoverStoreFiles(damagedStore: damagedStoreURL))
    }

    /// The history in memory only; the store that did not open stays where it is, and is a leftover until it can.
    private func inMemory() -> OpenedHistory {
        OpenedHistory(
            persistence: InMemoryHistoryPersistence(), error: .openFailed,
            leftovers: LeftoverStoreFiles(damagedStore: damagedStoreURL, unopenedStore: storeURL))
    }
}

/// What the store file is, told from its first bytes.
enum StoreFileCheck: Equatable, Sendable {
    case missing
    /// Starts with the SQLite header. It may still be damaged inside, or need a migration this build cannot do.
    case database
    /// Exists and can be read, but is not a SQLite database: empty, cut short or something else.
    case notADatabase
    /// Exists but cannot be read, for example for lack of permission.
    case unreadable

    /// The 16 bytes every SQLite database file starts with.
    static let sqliteHeader = Data("SQLite format 3\0".utf8)

    static func check(_ url: URL) -> StoreFileCheck {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return .missing
        }
        let header: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer {
                do {
                    try handle.close()
                } catch {
                    AppLogger.history.error("Could not close the history store after checking it")
                }
            }
            header = try handle.read(upToCount: sqliteHeader.count) ?? Data()
        } catch {
            return .unreadable
        }
        return header == sqliteHeader ? .database : .notADatabase
    }
}

/// Files of a saved history that this session does not use: the copy of a store that could not be opened
/// (`History.store.damaged`), and, while it cannot be opened, the store itself. They are told apart from the
/// history in use so that nothing deletes data they may still need, such as the images they reference.
@MainActor
protocol HistoryLeftovers: AnyObject {
    /// Whether any of the files exists. Reads the file system.
    func hasFiles() -> Bool
}

/// `HistoryLeftovers` on disk.
@MainActor
final class LeftoverStoreFiles: HistoryLeftovers {
    let damagedStore: URL
    /// The store this session could not open, or nil when it is in use.
    let unopenedStore: URL?

    init(damagedStore: URL, unopenedStore: URL? = nil) {
        self.damagedStore = damagedStore
        self.unopenedStore = unopenedStore
    }

    func hasFiles() -> Bool {
        let fileManager = FileManager.default
        return ([damagedStore] + [unopenedStore].compactMap { $0 })
            .flatMap(StoreFiles.urls(forStoreAt:))
            .contains { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
    }
}
