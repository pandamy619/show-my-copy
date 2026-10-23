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
        #expect(record.payload == Data("Hello, мир".utf8))
        #expect(record.contentHash == original.contentHash.description)
        #expect(record.byteSize == original.byteSize)
        #expect(record.previewText == original.previewText)
        #expect(record.date == date)
        #expect(record.sourceAppBundleIdentifier == "com.apple.Notes")
        #expect(record.sourceAppName == "Notes")
        #expect(!record.isConcealed)
        #expect(record.expiresAt == nil)
        #expect(!record.isPinned)
        #expect(record.schemaVersion == StoredEntryRecord.currentSchemaVersion)
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
        #expect(try FakeSecretSealer().open(record.payload) != Data("hunter2".utf8))
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

    @Test func tamperedSealedPayloadIsUnreadable() throws {
        let record = try #require(try coder.record(for: entry("hunter2", concealed: true)))
        let truncated = record.replacingPayload(with: record.payload.prefix(3))
        #expect(coder.decode(truncated) == .unreadable)
    }

    @Test func invalidTextIsUnreadable() throws {
        let record = try #require(try coder.record(for: entry("plain")))
        #expect(coder.decode(record.replacingPayload(with: Data([0xFF, 0xFE]))) == .unreadable)
    }

    @Test func unknownKindOrNewerSchemaIsUnsupported() throws {
        let record = try #require(try coder.record(for: entry("plain")))
        #expect(coder.decode(record.replacingKind(with: "hologram")) == .unsupported)
        let newer = record.replacingSchemaVersion(with: StoredEntryRecord.currentSchemaVersion + 1)
        #expect(coder.decode(newer) == .unsupported)
    }
}

extension StoredEntryRecord {
    func replacingPayload(with payload: Data) -> StoredEntryRecord {
        changed { $0.payload = payload }
    }

    func replacingKind(with kind: String) -> StoredEntryRecord {
        changed { $0.kind = kind }
    }

    func replacingSchemaVersion(with version: Int) -> StoredEntryRecord {
        changed { $0.schemaVersion = version }
    }

    private func changed(_ change: (inout StoredEntryRecord) -> Void) -> StoredEntryRecord {
        var copy = self
        change(&copy)
        return copy
    }
}
