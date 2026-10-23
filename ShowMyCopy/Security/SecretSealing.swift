import Foundation

/// Encrypts and decrypts secrets, such as concealed clipboard entries, before they are written to disk.
///
/// Implementations must authenticate the data: `open` throws for data that was changed or sealed with another key.
protocol SecretSealing: Sendable {
    func seal(_ plaintext: Data) throws -> Data
    func open(_ sealed: Data) throws -> Data
}
