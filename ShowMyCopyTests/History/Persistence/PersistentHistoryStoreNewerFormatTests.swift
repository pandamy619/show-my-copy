import Foundation
import Testing

@testable import ShowMyCopy

/// Records a newer version of the app wrote: a kind, a sealed format or a payload layout this version does not know.
/// An older build that runs afterwards (a downgrade, a second copy from Xcode) must leave them, and their blobs,
/// exactly as they are, rather than delete them as damaged.
@MainActor
struct PersistentHistoryStoreNewerFormatTests {
    private let disk = FakeHistoryPersistence()
    private let blobs = InMemoryBlobStore()
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let sealer = FakeSecretSealer()
    /// A padded payload whose format byte this version does not write.
    private let newerPayload = Data([0, 0, 0, 1, StoredPayload.format + 1]) + Data(count: 59)

    private func record(
        id: UUID = UUID(), kind: String = "text", payload: Data, concealed: Bool = false, expiresAt: Date? = nil,
        blobIDs: [UUID] = []
    ) -> StoredEntryRecord {
        StoredEntryRecord(
            id: id, kind: kind, payload: payload, contentHash: concealed ? nil : "00ff", byteSize: 0,
            previewText: concealed ? nil : "", date: start, sourceAppBundleIdentifier: nil, sourceAppName: nil,
            isConcealed: concealed, expiresAt: expiresAt, isPinned: false, blobIDs: blobIDs)
    }

    private struct Saved {
        /// The first three are of a newer shape; the last only looks like one and is unreadable.
        var newer: [StoredEntryRecord]
        var blob: BlobID
        var damaged: UUID
    }

    /// One record of each newer shape, with a blob, saved beside a readable entry and a damaged one.
    private func saveNewerRecords() throws -> Saved {
        let blob = BlobID()
        blobs.write(Data([1, 2, 3]), as: blob)
        let password = UUID()
        let newer = [
            record(payload: Data([StoredPayload.format + 1, 0x61])),
            record(kind: "hologram", payload: Data([StoredPayload.format, 0x61]), blobIDs: [blob.uuid]),
            record(
                id: password, payload: try sealer.seal(newerPayload, boundTo: .historyEntry(password)),
                concealed: true, expiresAt: start + 600),
            // Sealed with a format version this app does not know: `FakeSecretSealer` puts its key first, so a
            // leading byte it does not know fails like a newer version byte would for the real sealer.
            record(payload: Data([0, 0, 0, 1, StoredPayload.format + 1]), concealed: true, expiresAt: start + 600),
        ]
        let damaged = record(payload: Data([0, 0x61]))
        try disk.insert(newer + [damaged])
        disk.makeStore(sealer: sealer, now: start, blobs: blobs).record(text: "readable", sourceApp: nil, at: start)
        return Saved(newer: newer, blob: blob, damaged: damaged.id)
    }

    @Test func recordsOfANewerVersionSurviveALaunchWithTheirBlobs() throws {
        let saved = try saveNewerRecords()

        let store = disk.makeStore(sealer: sealer, now: start + 1, blobs: blobs)

        #expect(store.entries.map(\.text) == ["readable"])
        #expect(disk.records[saved.damaged] == nil)
        for record in saved.newer.prefix(3) {
            #expect(disk.records[record.id] == record)
        }
        #expect(blobs.allIDs().contains(saved.blob))
    }

    @Test func aRecordSealedWithAnUnknownKeyByteIsStillDeleted() throws {
        // Not a newer format: `FakeSecretSealer` fails authentication, as the real sealer does for another key.
        let saved = try saveNewerRecords()
        _ = disk.makeStore(sealer: sealer, now: start + 1, blobs: blobs)
        #expect(disk.records[saved.newer[3].id] == nil)
    }

    @Test func laterChangesLeaveTheNewerRecordsAsTheyAre() throws {
        let saved = try saveNewerRecords()
        let kept = Array(saved.newer.prefix(3))
        let store = disk.makeStore(sealer: sealer, now: start + 1, blobs: blobs)
        disk.resetCalls()

        store.record(text: "later", sourceApp: nil, at: start + 2)
        store.limitExpiry(to: start + 3)
        store.removeExpired(at: start + 4)
        store.removeConcealed()
        store.clear(keepingPinned: true)

        for record in kept {
            #expect(disk.records[record.id] == record)
        }
        #expect(blobs.allIDs().contains(saved.blob))
        let keptIDs = Set(kept.map(\.id))
        #expect(disk.changes.allSatisfy { change in change.saved.allSatisfy { !keptIDs.contains($0.id) } })
    }

    @Test func clearHistoryDeletesThemWithEverythingElse() throws {
        let saved = try saveNewerRecords()
        let store = disk.makeStore(sealer: sealer, now: start + 1, blobs: blobs)

        store.clear(keepingPinned: false)

        #expect(disk.records.isEmpty)
        #expect(!blobs.allIDs().contains(saved.blob))
    }

    @Test func aWaitingPasswordThatTurnsOutNewerIsLeftAlone() async throws {
        // The key was not loaded at launch, so the password waited; once the key loads it turns out to be of a newer
        // format: it stays on disk, unopened and unchanged, and stops waiting.
        let password = UUID()
        let sealed = try sealer.seal(newerPayload, boundTo: .historyEntry(password))
        let waiting = record(id: password, payload: sealed, concealed: true, expiresAt: start + 600)
        try disk.insert([waiting])
        let locked = KeyTroubleSealer(failure: .keyNotLoaded)
        let store = disk.makeStore(sealer: locked, now: start + 1)
        #expect(disk.records[waiting.id] == waiting)

        await store.loadPasswordKey()
        store.limitExpiry(to: start + 2)

        #expect(disk.records[waiting.id] == waiting)
        #expect(store.entries.isEmpty)
    }
}
