import Foundation

/// Turns history entries into the records written to disk and back. Concealed entries are sealed with `sealer`.
///
/// Without a sealer concealed entries are not written at all: they stay in memory until they expire or the app quits,
/// and saved concealed records cannot be opened. A sealer whose key cannot be used now (not loaded yet, locked,
/// denied) is told apart from data that cannot be opened: such a record waits on disk (`Decoded.waitsForKey`).
struct StoredEntryCoder: Sendable {
    /// What a saved record turned out to be.
    enum Decoded: Equatable, Sendable {
        case entry(ClipboardEntry)
        /// Damaged, of an unknown kind, or a password that cannot be opened (the key is gone or another one, or the
        /// data was changed). It is of no use to anyone any more and should be deleted.
        case unreadable
        /// A password that cannot be opened now because the key cannot be used now: not loaded yet, the Mac is
        /// locked or access was denied. The data may be fine, so it is kept and opened once the key loads.
        case waitsForKey
    }

    /// Sealed data is padded to a multiple of this many bytes, so its size does not tell a password's length.
    static let sealedBlockSize = 64

    let sealer: (any SecretSealing)?
    let hasher: any ContentHasher

    /// The record to write for `entry`, or nil when the entry is kept in memory only: a concealed entry without
    /// a sealer. Throws `sealFailed` when sealing a concealed entry fails, also while the sealer's key is not loaded.
    func record(for entry: ClipboardEntry) throws(HistoryPersistenceError) -> StoredEntryRecord? {
        let payload = entry.content.storedPayload
        var record = StoredEntryRecord(
            id: entry.id,
            kind: entry.kind.rawValue,
            payload: payload,
            contentHash: entry.contentHash.description,
            byteSize: entry.byteSize,
            previewText: entry.previewText,
            date: entry.date,
            sourceAppBundleIdentifier: entry.sourceApp?.bundleIdentifier,
            sourceAppName: entry.sourceApp?.name,
            isConcealed: entry.isConcealed,
            expiresAt: entry.expiresAt,
            isPinned: entry.isPinned,
            blobIDs: entry.content.blobIDs.map(\.uuid)
        )
        guard entry.isConcealed else {
            return record
        }
        guard let sealer else {
            return nil
        }
        do {
            record.payload = try sealer.seal(Self.padded(payload))
        } catch SecretSealingError.keyNotLoaded {
            AppLogger.history.info("A password waits for its key before it is saved")
            throw .sealFailed
        } catch {
            AppLogger.history.error("Could not encrypt a password for the saved history")
            throw .sealFailed
        }
        record.contentHash = nil
        record.previewText = nil
        record.byteSize = 0
        return record
    }

    /// The entry a saved record holds. Its hash and preview are made again from the content, so a concealed entry
    /// gets them back after its payload is opened.
    func decode(_ record: StoredEntryRecord) -> Decoded {
        guard let kind = ClipboardContent.Kind(rawValue: record.kind) else {
            return .unreadable
        }
        var payload = record.payload
        if record.isConcealed {
            switch open(payload) {
            case .opened(let opened):
                payload = opened
            case .waitsForKey:
                return .waitsForKey
            case .unreadable:
                return .unreadable
            }
        }
        guard let content = ClipboardContent(kind: kind, storedPayload: payload) else {
            return .unreadable
        }
        let sourceApp: SourceApp? =
            if record.sourceAppBundleIdentifier == nil && record.sourceAppName == nil {
                nil
            } else {
                SourceApp(bundleIdentifier: record.sourceAppBundleIdentifier, name: record.sourceAppName)
            }
        return .entry(
            ClipboardEntry(
                id: record.id,
                content: content,
                contentHash: hasher.hash(content),
                date: record.date,
                sourceApp: sourceApp,
                isConcealed: record.isConcealed,
                expiresAt: record.expiresAt,
                isPinned: record.isPinned
            )
        )
    }

    private enum Opened {
        case opened(Data)
        case waitsForKey
        case unreadable
    }

    private func open(_ sealed: Data) -> Opened {
        guard let sealer else {
            return .unreadable
        }
        let padded: Data
        do {
            padded = try sealer.open(sealed)
        } catch let error as SecretSealingError where error.isAboutTheKey {
            return .waitsForKey
        } catch {
            return .unreadable
        }
        return Self.unpadded(padded).map(Opened.opened) ?? .unreadable
    }

    /// The length as 4 big-endian bytes, the data, then zeros up to a multiple of `sealedBlockSize`.
    private static func padded(_ data: Data) -> Data {
        let length = UInt32(clamping: data.count)
        var result = Data([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) })
        result.append(data)
        let remainder = result.count % sealedBlockSize
        if remainder != 0 {
            result.append(Data(count: sealedBlockSize - remainder))
        }
        return result
    }

    private static func unpadded(_ padded: Data) -> Data? {
        let bytes = [UInt8](padded)
        guard bytes.count >= 4 else {
            return nil
        }
        let length = bytes[0..<4].reduce(0) { ($0 << 8) | Int($1) }
        guard length <= bytes.count - 4 else {
            return nil
        }
        return Data(bytes[4..<(4 + length)])
    }
}

extension ClipboardContent {
    /// The content's data as it is written to disk, before sealing, in the `StoredPayload` layout. An image's
    /// payload holds its blob IDs and metadata, never the image data.
    var storedPayload: Data {
        StoredPayload.encode(self)
    }

    /// The content saved as `storedPayload`, or nil when the data is not valid for `kind`.
    init?(kind: Kind, storedPayload payload: Data) {
        guard let content = StoredPayload.decode(kind, from: payload) else {
            return nil
        }
        self = content
    }
}
