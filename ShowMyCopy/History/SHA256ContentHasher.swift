import CryptoKit
import Foundation

/// SHA-256 content hashes.
struct SHA256ContentHasher: ContentHasher {
    func digest(of data: Data) -> ContentHash {
        ContentHash(bytes: Array(SHA256.hash(data: data)))
    }
}
