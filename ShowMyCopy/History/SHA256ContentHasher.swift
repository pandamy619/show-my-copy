import CryptoKit
import Foundation

/// SHA-256 content hashes. Kept in its own file because CryptoKit exists only on Apple platforms.
struct SHA256ContentHasher: ContentHasher {
    func digest(of data: Data) -> ContentHash {
        ContentHash(bytes: Array(SHA256.hash(data: data)))
    }
}
