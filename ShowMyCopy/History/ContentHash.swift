import Foundation

/// A digest of an entry's content. Entries with the same hash hold the same content, so a copy of content that is
/// already in the history moves that entry to the top instead of adding another one.
struct ContentHash: Hashable, Sendable, CustomStringConvertible {
    let bytes: [UInt8]

    /// Lower-case hexadecimal, for storage keys. Not for logs: a hash of a short password can be guessed.
    var description: String {
        bytes.map { byte in
            let hex = String(byte, radix: 16)
            return byte < 0x10 ? "0" + hex : hex
        }
        .joined()
    }

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }
}

/// Computes content hashes. The app uses `SHA256ContentHasher`; the protocol keeps CryptoKit out of everything else.
protocol ContentHasher: Sendable {
    /// The digest of `data`. Equal data must always give an equal digest, across launches and app versions.
    func digest(of data: Data) -> ContentHash
}

extension ContentHasher {
    func hash(_ content: ClipboardContent) -> ContentHash {
        digest(of: content.canonicalBytes)
    }
}
