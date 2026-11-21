import CryptoKit
import Foundation

/// A code shown to the user and the moment it stops being valid.
struct OneTimeCode: Equatable, Sendable {
    /// The digits, with leading zeros kept ("007081").
    let digits: String
    /// The start of the next period: after this the account gives a different code.
    let validUntil: Date
}

/// Time-based one-time codes, RFC 6238, on top of HMAC-based codes, RFC 4226. Pure computation: give it the time.
enum TOTP {
    /// The code the account shows at `now`, and when it changes.
    static func code(for account: OneTimeCodeAccount, at now: Date) -> OneTimeCode {
        let period = TimeInterval(max(account.period, 1))
        // Before 1970 there is no sensible counter; such a clock is a broken clock, so clamp instead of trapping.
        let counter = UInt64(max(0, (now.timeIntervalSince1970 / period).rounded(.down)))
        let validUntil = Date(timeIntervalSince1970: TimeInterval(counter + 1) * period)
        return OneTimeCode(
            digits: hotp(
                secret: account.secret, counter: counter, algorithm: account.algorithm, digits: account.digits
            ),
            validUntil: validUntil
        )
    }

    /// RFC 4226 §5.3: the HMAC of the big-endian counter, dynamically truncated to 31 bits, modulo 10^digits.
    static func hotp(
        secret: Data, counter: UInt64, algorithm: OneTimeCodeAccount.Algorithm, digits: OneTimeCodeAccount.Digits
    ) -> String {
        let key = SymmetricKey(data: secret)
        let message = withUnsafeBytes(of: counter.bigEndian) { Data($0) }
        let mac: [UInt8] =
            switch algorithm {
            case .sha1:
                Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
            case .sha256:
                Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
            case .sha512:
                Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
            }
        // Every algorithm gives at least 20 bytes, so offset + 3 (at most 18) is always inside.
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let truncated =
            UInt32(mac[offset] & 0x7F) << 24
            | UInt32(mac[offset + 1]) << 16
            | UInt32(mac[offset + 2]) << 8
            | UInt32(mac[offset + 3])
        let modulus = UInt32(digits.rawValue == 8 ? 100_000_000 : 1_000_000)
        let value = String(truncated % modulus)
        return String(repeating: "0", count: digits.rawValue - value.count) + value
    }
}
