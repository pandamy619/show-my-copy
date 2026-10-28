import Foundation
import Testing

@testable import ShowMyCopy

/// Opens a store like SwiftData would: fails as its switches below say, and creates an empty SQLite file when there is
/// none.
@MainActor
private final class StoreOpeningSpy {
    /// The first `transientFailures` calls fail whatever the file holds, like a store that is busy for a moment.
    var transientFailures = 0
    /// Fails every call while the store file exists, like a store this build cannot open.
    var failsWhileTheStoreExists = false
    /// Fails every call, also for a new store, like a disk that is full.
    var alwaysFails = false
    private(set) var calls = 0

    func open(_ url: URL) throws(HistoryPersistenceError) -> any HistoryPersistence {
        calls += 1
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        if alwaysFails || calls <= transientFailures || (failsWhileTheStoreExists && exists) {
            throw .openFailed
        }
        if !exists {
            do {
                try HistoryStoreOpenerTests.sqliteHeader.write(to: url)
            } catch {
                throw .openFailed
            }
        }
        return InMemoryHistoryPersistence()
    }
}

@MainActor
struct HistoryStoreOpenerTests {
    static let sqliteHeader = Data("SQLite format 3\0".utf8) + Data(count: 84)
    private let spy = StoreOpeningSpy()

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func open(in folder: URL, defaults: UserDefaults, at date: Date? = nil) -> OpenedHistory {
        let spy = spy
        let openStore: (URL) throws(HistoryPersistenceError) -> any HistoryPersistence = { url in
            try spy.open(url)
        }
        return HistoryStoreOpener(directory: folder, defaults: defaults, now: date ?? now, openStore: openStore).open()
    }

    private func damagedCopy(in folder: URL, movedAsideAt date: Date) throws {
        try TemporaryFolder.write(to: "History.store.damaged", in: folder)
        try TemporaryFolder.write(to: "History.store.damaged-wal", in: folder)
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: folder.appending(path: "History.store.damaged").path(percentEncoded: false))
    }

    private func modificationDate(of name: String, in folder: URL) throws -> Date? {
        let path = folder.appending(path: name).path(percentEncoded: false)
        return try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    private func savedStore(in folder: URL, data: Data = sqliteHeader + Data("history".utf8)) throws {
        try TemporaryFolder.write(data, to: "History.store", in: folder)
        try TemporaryFolder.write(to: "History.store-wal", in: folder)
    }

    private func storeData(in folder: URL, named name: String = "History.store") throws -> Data {
        try #require(FileManager.default.contents(atPath: folder.appending(path: name).path(percentEncoded: false)))
    }

    @Test func aStoreThatOpensIsUsed() throws {
        try TemporaryFolder.with { folder in
            try TestDefaults.with { defaults in
                try savedStore(in: folder)
                let opened = open(in: folder, defaults: defaults)
                #expect(opened.error == nil)
                #expect(spy.calls == 1)
                #expect(!TemporaryFolder.exists("History.store.damaged", in: folder))
            }
        }
    }

    @Test func aStoreThatFailsForAMomentIsTriedAgain() throws {
        try TemporaryFolder.with { folder in
            try TestDefaults.with { defaults in
                try savedStore(in: folder)
                spy.transientFailures = HistoryStoreOpener.attemptsPerLaunch - 1

                let opened = open(in: folder, defaults: defaults)
                #expect(opened.error == nil)
                #expect(spy.calls == HistoryStoreOpener.attemptsPerLaunch)
                #expect(try storeData(in: folder) == Self.sqliteHeader + Data("history".utf8))
            }
        }
    }

    /// Another build, a full disk or a busy store: the history is not moved aside after one bad launch.
    @Test func aDatabaseThatCannotBeOpenedIsLeftWhereItIs() throws {
        try TemporaryFolder.with { folder in
            try TestDefaults.with { defaults in
                try savedStore(in: folder)
                spy.failsWhileTheStoreExists = true

                let opened = open(in: folder, defaults: defaults)
                #expect(opened.error == .openFailed)
                #expect(opened.persistence is InMemoryHistoryPersistence)
                #expect(spy.calls == HistoryStoreOpener.attemptsPerLaunch)
                #expect(try storeData(in: folder) == Self.sqliteHeader + Data("history".utf8))
                #expect(TemporaryFolder.exists("History.store-wal", in: folder))
                #expect(!TemporaryFolder.exists("History.store.damaged", in: folder))
                #expect(opened.leftovers?.hasFiles() == true)
            }
        }
    }

    @Test func aDatabaseIsMovedAsideOnlyAfterFailingOnSeveralLaunchesInARow() throws {
        try TemporaryFolder.with { folder in
            try TestDefaults.with { defaults in
                try savedStore(in: folder)
                spy.failsWhileTheStoreExists = true
                for _ in 1..<HistoryStoreOpener.failedLaunchesBeforeReset {
                    #expect(open(in: folder, defaults: defaults).error == .openFailed)
                }
                #expect(!TemporaryFolder.exists("History.store.damaged", in: folder))

                // The moved store is gone, so a new one opens.
                let opened = open(in: folder, defaults: defaults)
                #expect(opened.error == .storeReset)
                #expect(
                    try storeData(in: folder, named: "History.store.damaged")
                        == Self.sqliteHeader + Data("history".utf8))
                #expect(TemporaryFolder.exists("History.store.damaged-wal", in: folder))
                #expect(!TemporaryFolder.exists("History.store-wal", in: folder))
            }
        }
    }

    @Test func aLaunchThatOpensTheStoreStartsTheCountAgain() throws {
        try TemporaryFolder.with { folder in
            try TestDefaults.with { defaults in
                try savedStore(in: folder)
                for _ in 1..<HistoryStoreOpener.failedLaunchesBeforeReset {
                    spy.failsWhileTheStoreExists = true
                    #expect(open(in: folder, defaults: defaults).error == .openFailed)
                    spy.failsWhileTheStoreExists = false
                    #expect(open(in: folder, defaults: defaults).error == nil)
                }
                spy.failsWhileTheStoreExists = true
                #expect(open(in: folder, defaults: defaults).error == .openFailed)
                #expect(!TemporaryFolder.exists("History.store.damaged", in: folder))
            }
        }
    }

    @Test(arguments: [Data("not a database at all, just bytes".utf8), Data(), Data("SQLite".utf8)])
    func aFileThatIsNotADatabaseIsMovedAsideAtOnce(contents: Data) throws {
        try TemporaryFolder.with { folder in
            try TestDefaults.with { defaults in
                try savedStore(in: folder, data: contents)
                spy.failsWhileTheStoreExists = true

                let opened = open(in: folder, defaults: defaults)
                #expect(opened.error == .storeReset)
                #expect(try storeData(in: folder, named: "History.store.damaged") == contents)
                #expect(try storeData(in: folder) == Self.sqliteHeader)
            }
        }
    }

    @Test func aNewerDamagedCopyReplacesTheOlderOne() throws {
        try TemporaryFolder.with { folder in
            try TestDefaults.with { defaults in
                try TemporaryFolder.write(Data("older".utf8), to: "History.store.damaged", in: folder)
                try TemporaryFolder.write(Data("older".utf8), to: "History.store.damaged-shm", in: folder)
                try savedStore(in: folder, data: Data("newer".utf8))
                spy.failsWhileTheStoreExists = true

                #expect(open(in: folder, defaults: defaults).error == .storeReset)
                #expect(try storeData(in: folder, named: "History.store.damaged") == Data("newer".utf8))
                #expect(!TemporaryFolder.exists("History.store.damaged-shm", in: folder))
            }
        }
    }

    @Test func withoutAStoreAFailureMovesNothing() throws {
        try TemporaryFolder.with { folder in
            try TestDefaults.with { defaults in
                spy.alwaysFails = true
                for _ in 0...HistoryStoreOpener.failedLaunchesBeforeReset {
                    let opened = open(in: folder, defaults: defaults)
                    #expect(opened.error == .openFailed)
                    #expect(opened.persistence is InMemoryHistoryPersistence)
                }
                let names = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
                #expect(names.isEmpty)
            }
        }
    }

    @Test func noDamagedCopyMeansNoLeftovers() throws {
        try TemporaryFolder.with { folder in
            try TestDefaults.with { defaults in
                #expect(open(in: folder, defaults: defaults).leftovers?.hasFiles() == false)
                try TemporaryFolder.write(to: "History.store.damaged", in: folder)
                #expect(open(in: folder, defaults: defaults).leftovers?.hasFiles() == true)
            }
        }
    }

    // MARK: - Age of the damaged copy

    @Test func aDamagedCopyIsDeletedAtTheFirstLaunchAWeekAfterItWasMovedAside() throws {
        try TemporaryFolder.with { folder in
            try TestDefaults.with { defaults in
                try damagedCopy(in: folder, movedAsideAt: now - HistoryStoreOpener.damagedCopyLifetime - 1)
                let opened = open(in: folder, defaults: defaults)
                #expect(!TemporaryFolder.exists("History.store.damaged", in: folder))
                #expect(!TemporaryFolder.exists("History.store.damaged-wal", in: folder))
                #expect(opened.leftovers?.hasFiles() == false)
            }
        }
    }

    @Test func aYoungerDamagedCopyIsKept() throws {
        try TemporaryFolder.with { folder in
            try TestDefaults.with { defaults in
                try damagedCopy(in: folder, movedAsideAt: now - HistoryStoreOpener.damagedCopyLifetime + 60)
                #expect(open(in: folder, defaults: defaults).leftovers?.hasFiles() == true)
                #expect(TemporaryFolder.exists("History.store.damaged-wal", in: folder))
            }
        }
    }

    /// The store's own date is when it was last written; the week counts from when it was moved aside.
    @Test func aCopyIsDatedWhenItIsMovedAside() throws {
        try TemporaryFolder.with { folder in
            try TestDefaults.with { defaults in
                try savedStore(in: folder, data: Data("damaged".utf8))
                try FileManager.default.setAttributes(
                    [.modificationDate: now - 30 * 24 * 3600],
                    ofItemAtPath: folder.appending(path: "History.store").path(percentEncoded: false))
                spy.failsWhileTheStoreExists = true

                #expect(open(in: folder, defaults: defaults).error == .storeReset)
                let date = try #require(try modificationDate(of: "History.store.damaged", in: folder))
                #expect(abs(date.timeIntervalSince(now)) < 1)
                #expect(open(in: folder, defaults: defaults, at: now + 3600).leftovers?.hasFiles() == true)
            }
        }
    }
}
