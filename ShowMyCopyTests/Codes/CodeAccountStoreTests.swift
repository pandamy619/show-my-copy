import Foundation
import Testing

@testable import ShowMyCopy

@MainActor
struct CodeAccountStoreTests {
    private let persistence = InMemoryCodeAccounts()
    private let clock = ManualDate(CodeFixtures.date)

    private func makeStore(_ persistence: InMemoryCodeAccounts? = nil) -> CodeAccountStore {
        CodeAccountStore(persistence: persistence ?? self.persistence, now: clock.read)
    }

    @Test func startsLoadingAndLoadsTheSavedAccountsSorted() async {
        let zulu = CodeFixtures.stored(issuer: "Zulu")
        let alpha = CodeFixtures.stored(issuer: "alpha")
        let persistence = InMemoryCodeAccounts(saved: [zulu, alpha])
        let store = makeStore(persistence)
        #expect(store.availability == .loading)

        await store.load()

        #expect(store.availability == .ready)
        #expect(store.accounts == [alpha, zulu])
        #expect(persistence.loadCount == 1)
    }

    @Test func addsNewAccountsOnceAndSavesTheWholeList() async {
        let store = makeStore()
        let github = CodeFixtures.account()
        let google = CodeFixtures.account(
            issuer: "Google", name: "me@gmail.com", secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")

        let result = await store.add([github, google, github])
        await store.finishSaving()

        #expect(result == CodeAccountStore.AddResult(added: 2, duplicates: 1))
        #expect(store.accounts.map(\.account) == [github, google])
        #expect(store.accounts.allSatisfy { $0.addedAt == CodeFixtures.date })
        #expect(persistence.saved.map(\.account) == [github, google])
        #expect(persistence.saveCount == 1)
    }

    @Test func anAccountThatIsInTheListAlreadyIsNotAddedAgain() async {
        let saved = CodeFixtures.stored()
        let store = makeStore(InMemoryCodeAccounts(saved: [saved]))

        let result = await store.add([CodeFixtures.account()])

        #expect(result == CodeAccountStore.AddResult(added: 0, duplicates: 1))
        #expect(store.accounts == [saved])
    }

    @Test func removingDeletesTheAccountAndSavesTheRest() async {
        let github = CodeFixtures.stored()
        let google = CodeFixtures.stored(issuer: "Google", secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        let persistence = InMemoryCodeAccounts(saved: [github, google])
        let store = makeStore(persistence)

        await store.remove(id: github.id)
        await store.finishSaving()

        #expect(store.accounts == [google])
        #expect(persistence.saved == [google])
        await store.remove(id: github.id)
        await store.finishSaving()
        #expect(persistence.saveCount == 1)
    }

    @Test func aFailedSaveKeepsTheAccountsInMemoryAndSaysSo() async {
        persistence.setSaveError(.writeFailed)
        let store = makeStore()

        await store.add([CodeFixtures.account()])
        await store.finishSaving()

        #expect(store.accounts.count == 1)
        #expect(store.lastSaveFailed)
        #expect(persistence.saved.isEmpty)

        persistence.setSaveError(nil)
        await store.add([CodeFixtures.account(issuer: "Google", secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")])
        await store.finishSaving()
        #expect(!store.lastSaveFailed)
        #expect(persistence.saved.count == 2)
    }

    @Test(arguments: [CodeAccountsLoad.keyUnavailable, .damaged, .newerFormat, .unreadable])
    func aFileThatCannotBeReadIsNeverWrittenOver(loaded: CodeAccountsLoad) async {
        let saved = CodeFixtures.stored(issuer: "Saved")
        let persistence = InMemoryCodeAccounts(saved: [saved], loadResult: loaded)
        let store = makeStore(persistence)

        await store.load()
        await store.add([CodeFixtures.account()])
        await store.remove(id: store.accounts[0].id)
        await store.add([CodeFixtures.account()])
        await store.finishSaving()

        #expect(store.availability == .unavailable(loaded))
        #expect(store.accounts.map(\.account) == [CodeFixtures.account()])
        #expect(persistence.saveCount == 0)
        #expect(persistence.saved == [saved])
        // Nothing changes this session: the file is not read again.
        await store.load()
        #expect(persistence.loadCount == 1)
    }

    @Test func aLockedKeychainIsTriedAgainAndTheAccountsAddedMeanwhileAreKept() async {
        let saved = CodeFixtures.stored(issuer: "Saved")
        let persistence = InMemoryCodeAccounts(saved: [saved], loadResult: .keyLockedOut)
        let store = makeStore(persistence)
        await store.load()
        #expect(store.availability == .unavailable(.keyLockedOut))
        let pending = CodeFixtures.account(issuer: "Pending")
        await store.add([pending, saved.account])
        #expect(persistence.saveCount == 0)

        // The user is back at the unlocked Mac.
        persistence.setLoadResult(nil)
        await store.load()
        await store.finishSaving()

        #expect(store.availability == .ready)
        #expect(store.accounts.map(\.account) == [pending, saved.account])
        #expect(persistence.saved.map(\.account) == [pending, saved.account])
        // At launch, before the add (the Mac may have been unlocked since) and when the user came back.
        #expect(persistence.loadCount == 3)
    }

    @Test func loadsRunOnceAtATime() async {
        let store = makeStore(InMemoryCodeAccounts(saved: [CodeFixtures.stored()]))

        async let first: Void = store.load()
        async let second: Void = store.load()
        _ = await (first, second)

        #expect(persistence.loadCount <= 1)
        #expect(store.availability == .ready)
    }
}
