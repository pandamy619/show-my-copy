import Foundation
import Testing

@testable import ShowMyCopy

struct StoredEntryCoderTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)
    private let notes = SourceApp(bundleIdentifier: "com.apple.Notes", name: "Notes")
    private let hasher = SHA256ContentHasher()
    private let coder = StoredEntryCoder(sealer: FakeSecretSealer(), hasher: SHA256ContentHasher())

    private func entry(_ text: String, concealed: Bool = false, expiresAt: Date? = nil) -> ClipboardEntry {
        ClipboardEntry(
            text: text, date: date, sourceApp: notes, isConcealed: concealed, expiresAt: expiresAt, hasher: hasher)
    }

    private func decodedEntry(_ record: StoredEntryRecord) -> ClipboardEntry? {
        guard case .entry(let entry) = coder.decode(record) else {
            return nil
        }
        return entry
    }

    @Test func plainTextIsStoredAsItIs() throws {
        let original = entry("Hello, мир")
        let record = try #require(try coder.record(for: original))

        #expect(record.id == original.id)
        #expect(record.kind == "text")
        #expect(record.payload == Data([StoredPayload.format]) + Data("Hello, мир".utf8))
        #expect(record.contentHash == original.contentHash.description)
        #expect(record.byteSize == original.byteSize)
        #expect(record.previewText == original.previewText)
        #expect(record.date == date)
        #expect(record.sourceAppBundleIdentifier == "com.apple.Notes")
        #expect(record.sourceAppName == "Notes")
        #expect(!record.isConcealed)
        #expect(record.expiresAt == nil)
        #expect(!record.isPinned)
        #expect(record.blobIDs.isEmpty)
    }

    @Test func plainTextRoundTrips() throws {
        let original = entry("Hello, мир")
        let record = try #require(try coder.record(for: original))
        #expect(decodedEntry(record) == original)
    }

    @Test func entryWithoutSourceAppRoundTrips() throws {
        let original = ClipboardEntry(text: "no app", date: date, sourceApp: nil, hasher: hasher)
        let record = try #require(try coder.record(for: original))
        #expect(record.sourceAppBundleIdentifier == nil)
        #expect(record.sourceAppName == nil)
        #expect(decodedEntry(record) == original)
    }

    @Test func concealedTextIsSealedWithoutHashOrPreview() throws {
        let secret = entry("hunter2", concealed: true, expiresAt: date + 600)
        let record = try #require(try coder.record(for: secret))

        #expect(record.isConcealed)
        #expect(record.expiresAt == date + 600)
        // A plain hash of a password could be checked against a list of common passwords.
        #expect(record.contentHash == nil)
        #expect(record.previewText == nil)
        #expect(record.byteSize == 0)
        #expect(record.payload.range(of: Data("hunter2".utf8)) == nil)
        #expect(try FakeSecretSealer().open(record.payload, boundTo: .historyEntry(record.id)) != Data("hunter2".utf8))
    }

    @Test func aPasswordCopiedIntoAnotherRecordIsUnreadable() throws {
        // The sealed payload is bound to its record, so it opens nowhere else, and the record it was copied into
        // is of no use: it is deleted like any password that cannot be opened.
        let record = try #require(try coder.record(for: entry("hunter2", concealed: true)))
        let other = record.replacingID(with: UUID())
        #expect(coder.decode(other) == .unreadable)
        #expect(coder.decode(record) != .unreadable)
    }

    @Test func sealedPasswordsOfDifferentLengthsHaveTheSameSize() throws {
        let short = try #require(try coder.record(for: entry("abc", concealed: true)))
        let long = try #require(try coder.record(for: entry("a much longer password", concealed: true)))
        #expect(short.payload.count == long.payload.count)
    }

    @Test func concealedTextRoundTripsWithItsHashAndPreview() throws {
        let secret = entry("hunter2", concealed: true, expiresAt: date + 600)
        let record = try #require(try coder.record(for: secret))
        let loaded = try #require(decodedEntry(record))

        #expect(loaded == secret)
        #expect(loaded.contentHash == hasher.hash(.text("hunter2")))
        #expect(loaded.previewText == secret.previewText)
    }

    @Test func pinnedEntryKeepsItsPin() throws {
        let original = ClipboardEntry(
            content: .text("pinned"), contentHash: hasher.hash(.text("pinned")), date: date, sourceApp: nil,
            isPinned: true)
        let record = try #require(try coder.record(for: original))
        #expect(record.isPinned)
        #expect(decodedEntry(record)?.isPinned == true)
    }

    @Test func concealedEntryWithoutSealerIsNotStored() throws {
        let coder = StoredEntryCoder(sealer: nil, hasher: hasher)
        #expect(try coder.record(for: entry("hunter2", concealed: true)) == nil)
        #expect(try coder.record(for: entry("plain")) != nil)
    }

    @Test func failedSealingThrows() {
        let coder = StoredEntryCoder(sealer: FakeSecretSealer(failsToSeal: true), hasher: hasher)
        #expect(throws: HistoryPersistenceError.sealFailed) {
            try coder.record(for: entry("hunter2", concealed: true))
        }
    }

    @Test func recordSealedWithAnotherKeyIsUnreadable() throws {
        let other = StoredEntryCoder(sealer: FakeSecretSealer(key: 0x11), hasher: hasher)
        let record = try #require(try other.record(for: entry("hunter2", concealed: true)))
        #expect(coder.decode(record) == .unreadable)
    }

    @Test func concealedRecordWithoutSealerIsUnreadable() throws {
        let record = try #require(try coder.record(for: entry("hunter2", concealed: true)))
        #expect(StoredEntryCoder(sealer: nil, hasher: hasher).decode(record) == .unreadable)
    }

    @Test func concealedRecordWaitsWhileTheKeyCannotBeUsed() throws {
        let record = try #require(try coder.record(for: entry("hunter2", concealed: true)))
        let locked = StoredEntryCoder(sealer: KeyTroubleSealer(failure: .keyNotLoaded), hasher: hasher)
        let denied = StoredEntryCoder(
            sealer: KeyTroubleSealer(failure: .keyUnavailable(.accessDenied)), hasher: hasher)
        #expect(locked.decode(record) == .waitsForKey)
        #expect(denied.decode(record) == .waitsForKey)
    }

    @Test func tamperedSealedPayloadIsUnreadable() throws {
        let record = try #require(try coder.record(for: entry("hunter2", concealed: true)))
        let truncated = record.replacingPayload(with: record.payload.prefix(3))
        #expect(coder.decode(truncated) == .unreadable)
    }

    @Test func invalidTextIsUnreadable() throws {
        let record = try #require(try coder.record(for: entry("plain")))
        #expect(coder.decode(record.replacingPayload(with: Data([StoredPayload.format, 0xFF, 0xFE]))) == .unreadable)
        #expect(coder.decode(record.replacingPayload(with: Data())) == .unreadable)
    }

    @Test func textWithoutTheFormatByteIsNotRead() throws {
        let record = try #require(try coder.record(for: entry("plain")))
        // Only the first byte tells a newer format from damage: a stray byte above the format is left alone, one
        // below it (no version wrote it) is deleted.
        #expect(coder.decode(record.replacingPayload(with: Data("plain".utf8))) == .newerFormat)
        #expect(coder.decode(record.replacingPayload(with: Data([0] + "plain".utf8))) == .unreadable)
    }

    // A newer version of the app may add a kind, a sealed format or a payload layout: its records are left alone.

    @Test func unknownKindIsANewerFormat() throws {
        let record = try #require(try coder.record(for: entry("plain")))
        #expect(coder.decode(record.replacingKind(with: "hologram")) == .newerFormat)
    }

    @Test func payloadOfANewerFormatIsANewerFormat() throws {
        let record = try #require(try coder.record(for: entry("plain")))
        #expect(coder.decode(record.replacingPayload(with: Data([StoredPayload.format + 1, 0x68]))) == .newerFormat)
        #expect(coder.decode(record.replacingPayload(with: Data([0, 0x68]))) == .unreadable)
        #expect(StoredPayload.isNewerFormat(Data([2])))
        #expect(!StoredPayload.isNewerFormat(Data([StoredPayload.format])))
        #expect(!StoredPayload.isNewerFormat(Data()))
    }

    @Test func recordSealedByANewerVersionIsANewerFormat() throws {
        let record = try #require(try coder.record(for: entry("hunter2", concealed: true)))
        let newer = StoredEntryCoder(sealer: DataTroubleSealer(error: .newerFormatVersion(2)), hasher: hasher)
        #expect(newer.decode(record) == .newerFormat)
        let damaged = StoredEntryCoder(sealer: DataTroubleSealer(error: .unsupportedFormatVersion(0)), hasher: hasher)
        #expect(damaged.decode(record) == .unreadable)
    }

    @Test func sealedPayloadOfANewerFormatIsANewerFormat() throws {
        // The sealed data opens, and what is inside has a format byte this version does not write.
        let sealer = FakeSecretSealer()
        let record = try #require(try coder.record(for: entry("hunter2", concealed: true)))
        let inside = try sealer.seal(
            Data([0, 0, 0, 1, StoredPayload.format + 1]) + Data(count: 59), boundTo: .historyEntry(record.id))
        #expect(coder.decode(record.replacingPayload(with: inside)) == .newerFormat)
    }
}

extension StoredEntryRecord {
    func replacingPayload(with payload: Data) -> StoredEntryRecord {
        changed { $0.payload = payload }
    }

    func replacingID(with id: UUID) -> StoredEntryRecord {
        changed { $0.id = id }
    }

    func replacingKind(with kind: String) -> StoredEntryRecord {
        changed { $0.kind = kind }
    }

    private func changed(_ change: (inout StoredEntryRecord) -> Void) -> StoredEntryRecord {
        var copy = self
        change(&copy)
        return copy
    }
}
