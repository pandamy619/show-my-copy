import Foundation
import Testing

@testable import ShowMyCopy

/// Opens a store like SwiftData would: fails while the store file holds what `failsOn` says, and creates an empty
/// SQLite file when there is none.
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

    private func open(in folder: URL, defaults: UserDefaults) -> OpenedHistory {
        HistoryStoreOpener(directory: folder, defaults: defaults) { [spy] url throws(HistoryPersistenceError) in
            try spy.open(url)
        }
        .open()
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
            try TemporaryFolder.withDefaults { defaults in
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
            try TemporaryFolder.withDefaults { defaults in
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
            try TemporaryFolder.withDefaults { defaults in
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
            try TemporaryFolder.withDefaults { defaults in
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
            try TemporaryFolder.withDefaults { defaults in
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
            try TemporaryFolder.withDefaults { defaults in
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
            try TemporaryFolder.withDefaults { defaults in
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
            try TemporaryFolder.withDefaults { defaults in
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
            try TemporaryFolder.withDefaults { defaults in
                #expect(open(in: folder, defaults: defaults).leftovers?.hasFiles() == false)
                try TemporaryFolder.write(to: "History.store.damaged", in: folder)
                #expect(open(in: folder, defaults: defaults).leftovers?.hasFiles() == true)
            }
        }
    }
}
