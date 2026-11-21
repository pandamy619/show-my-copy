import Foundation
import Testing

@testable import ShowMyCopy

struct TOTPTests {
    private static let sha1Seed = Data("12345678901234567890".utf8)
    private static let sha256Seed = Data("12345678901234567890123456789012".utf8)
    private static let sha512Seed = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    private static func account(
        secret: Data, algorithm: OneTimeCodeAccount.Algorithm, digits: OneTimeCodeAccount.Digits = .eight
    ) -> OneTimeCodeAccount {
        OneTimeCodeAccount(
            issuer: "RFC", name: "6238", secret: secret, algorithm: algorithm, digits: digits, period: 30
        )
    }

    /// RFC 6238 Appendix B: time in seconds since 1970 and the 8-digit codes for each algorithm.
    @Test(arguments: [
        (59, "94287082", "46119246", "90693936"),
        (1_111_111_109, "07081804", "68084774", "25091201"),
        (1_111_111_111, "14050471", "67062674", "99943326"),
        (1_234_567_890, "89005924", "91819424", "93441116"),
        (2_000_000_000, "69279037", "90698825", "38618901"),
        (20_000_000_000, "65353130", "77737706", "47863826"),
    ])
    func matchesTheReferenceVectors(seconds: TimeInterval, sha1: String, sha256: String, sha512: String) {
        let now = Date(timeIntervalSince1970: seconds)
        #expect(TOTP.code(for: Self.account(secret: Self.sha1Seed, algorithm: .sha1), at: now).digits == sha1)
        #expect(TOTP.code(for: Self.account(secret: Self.sha256Seed, algorithm: .sha256), at: now).digits == sha256)
        #expect(TOTP.code(for: Self.account(secret: Self.sha512Seed, algorithm: .sha512), at: now).digits == sha512)
    }

    /// RFC 4226 Appendix D: the counter-based codes the time-based ones are built on.
    private static let counterBasedVectors: [(UInt64, String)] = Array(
        zip(
            0..<10,
            ["755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871", "520489"]
        )
    )

    @Test(arguments: counterBasedVectors)
    func matchesTheCounterBasedReferenceVectors(counter: UInt64, expected: String) {
        #expect(TOTP.hotp(secret: Self.sha1Seed, counter: counter, algorithm: .sha1, digits: .six) == expected)
    }

    @Test func sixDigitCodesAreTheLastSixOfTheEightDigitCode() {
        let now = Date(timeIntervalSince1970: 1_111_111_109)
        let code = TOTP.code(for: Self.account(secret: Self.sha1Seed, algorithm: .sha1, digits: .six), at: now)
        #expect(code.digits == "081804")
    }

    @Test func keepsLeadingZeros() {
        let now = Date(timeIntervalSince1970: 1_234_567_890)
        let code = TOTP.code(for: Self.account(secret: Self.sha1Seed, algorithm: .sha1, digits: .six), at: now)
        #expect(code.digits == "005924")
        #expect(code.digits.count == 6)
    }

    @Test func theCodeChangesAtTheStartOfTheNextPeriod() {
        let account = Self.account(secret: Self.sha1Seed, algorithm: .sha1)
        let atFiftyNine = TOTP.code(for: account, at: Date(timeIntervalSince1970: 59))
        #expect(atFiftyNine.validUntil == Date(timeIntervalSince1970: 60))
        #expect(TOTP.code(for: account, at: Date(timeIntervalSince1970: 59.999)) == atFiftyNine)
        #expect(TOTP.code(for: account, at: Date(timeIntervalSince1970: 30)) == atFiftyNine)
        let atSixty = TOTP.code(for: account, at: Date(timeIntervalSince1970: 60))
        #expect(atSixty.digits != atFiftyNine.digits)
        #expect(atSixty.validUntil == Date(timeIntervalSince1970: 90))
    }

    @Test func honoursTheAccountsPeriod() {
        let account = OneTimeCodeAccount(
            issuer: "", name: "", secret: Self.sha1Seed, algorithm: .sha1, digits: .six, period: 60
        )
        let code = TOTP.code(for: account, at: Date(timeIntervalSince1970: 119))
        // Counter 1, as RFC 4226 counter 1 for this seed.
        #expect(code.digits == "287082")
        #expect(code.validUntil == Date(timeIntervalSince1970: 120))
    }

    @Test func aClockBefore1970GivesTheFirstCodeInsteadOfTrapping() {
        let account = Self.account(secret: Self.sha1Seed, algorithm: .sha1, digits: .six)
        let code = TOTP.code(for: account, at: Date(timeIntervalSince1970: -1000))
        #expect(code.digits == "755224")
        #expect(code.validUntil == Date(timeIntervalSince1970: 30))
    }
}
