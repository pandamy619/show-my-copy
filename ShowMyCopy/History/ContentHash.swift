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

    /// The hash written as `description`, or nil when `hex` is not an even number of hexadecimal digits.
    init?(hex: String) {
        let digits = Array(hex.utf8)
        guard !digits.isEmpty, digits.count.isMultiple(of: 2) else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = Self.value(ofHexDigit: digits[index]), let low = Self.value(ofHexDigit: digits[index + 1])
            else {
                return nil
            }
            bytes.append(high << 4 | low)
        }
        self.bytes = bytes
    }

    private static func value(ofHexDigit digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            digit - UInt8(ascii: "A") + 10
        default:
            nil
        }
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
