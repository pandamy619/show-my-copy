import Foundation

@testable import ShowMyCopy

/// Accounts for tests.
enum CodeFixtures {
    static let date = Date(timeIntervalSince1970: 1_790_000_000)

    /// `secret` is Base32, as services show it; the account holds its bytes.
    static func account(
        issuer: String = "GitHub", name: String = "octocat", secret: String = "JBSWY3DPEHPK3PXP"
    ) -> OneTimeCodeAccount {
        OneTimeCodeAccount(
            issuer: issuer, name: name, secret: (try? Base32.decode(secret)) ?? Data(), algorithm: .sha1,
            digits: .six, period: OneTimeCodeAccount.defaultPeriod)
    }

    static func stored(
        issuer: String = "GitHub", name: String = "octocat", secret: String = "JBSWY3DPEHPK3PXP", addedAt: Date = date
    ) -> CodeAccount {
        CodeAccount(account: account(issuer: issuer, name: name, secret: secret), addedAt: addedAt)
    }

    static let exportURL =
        "otpauth-migration://offline?data=CjEKCkhlbGxvId6tvu8SGEV4YW1wbGU6YWxpY2VAZ29vZ2xlLmNvbRoHRXhhbXBsZTAC"
    static let addressURL = "otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP&issuer=GitHub"
}
