import Foundation
import Testing

@testable import ShowMyCopy

struct OTPAuthURLTests {
    private let secret = Data("Hello!".utf8) + Data([0xDE, 0xAD, 0xBE, 0xEF])

    @Test func parsesTheExampleFromTheFormatsDefinition() throws {
        let account = try OTPAuthURL.account(
            from: "otpauth://totp/Example:alice@google.com?secret=JBSWY3DPEHPK3PXP&issuer=Example")
        #expect(account.issuer == "Example")
        #expect(account.name == "alice@google.com")
        #expect(account.secret == secret)
        #expect(account.algorithm == .sha1)
        #expect(account.digits == .six)
        #expect(account.period == 30)
        #expect(account.displayName == "Example (alice@google.com)")
    }

    @Test func readsEveryParameter() throws {
        let account = try OTPAuthURL.account(
            from: "otpauth://totp/ACME%20Co:john.doe@email.com?secret=JBSWY3DPEHPK3PXP&issuer=ACME%20Co"
                + "&algorithm=sha256&digits=8&period=60")
        #expect(account.issuer == "ACME Co")
        #expect(account.name == "john.doe@email.com")
        #expect(account.algorithm == .sha256)
        #expect(account.digits == .eight)
        #expect(account.period == 60)
    }

    @Test func takesTheIssuerFromTheLabelWhenThereIsNoParameter() throws {
        let account = try OTPAuthURL.account(from: "otpauth://totp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP")
        #expect(account.issuer == "GitHub")
        #expect(account.name == "octocat")
    }

    @Test func theIssuerParameterWinsOverTheLabel() throws {
        let account = try OTPAuthURL.account(from: "otpauth://totp/Old:octocat?secret=JBSWY3DPEHPK3PXP&issuer=New")
        #expect(account.issuer == "New")
        #expect(account.name == "octocat")
    }

    @Test func aLabelWithoutAColonIsTheName() throws {
        let account = try OTPAuthURL.account(from: "otpauth://totp/octocat?secret=JBSWY3DPEHPK3PXP")
        #expect(account.issuer == "")
        #expect(account.name == "octocat")
        #expect(account.displayName == "octocat")
    }

    @Test func acceptsSpacesAndLowerCaseThatPeopleTypeOrCopy() throws {
        let account = try OTPAuthURL.account(
            from: "  OTPAUTH://TOTP/My Bank:me?secret=jbsw y3dp ehpk 3pxp&Issuer=My Bank\n")
        #expect(account.issuer == "My Bank")
        #expect(account.name == "me")
        #expect(account.secret == secret)
    }

    @Test(arguments: ["https://example.com/?secret=JBSWY3DPEHPK3PXP", "JBSWY3DPEHPK3PXP", "", "otpauth:"])
    func rejectsOtherAddresses(text: String) {
        #expect(throws: OTPAuthURL.ParsingError.notAnOTPAuthURL) {
            try OTPAuthURL.account(from: text)
        }
    }

    @Test func rejectsCounterBasedAccounts() {
        #expect(throws: OTPAuthURL.ParsingError.unsupportedType("hotp")) {
            try OTPAuthURL.account(from: "otpauth://hotp/Example:alice?secret=JBSWY3DPEHPK3PXP&counter=0")
        }
    }

    @Test(arguments: ["otpauth://totp/Example:alice?issuer=Example", "otpauth://totp/Example:alice?secret="])
    func rejectsAMissingSecret(text: String) {
        #expect(throws: OTPAuthURL.ParsingError.missingSecret) {
            try OTPAuthURL.account(from: text)
        }
    }

    @Test func rejectsASecretThatIsNotBase32() {
        #expect(throws: OTPAuthURL.ParsingError.invalidSecret(.invalidCharacter("1"))) {
            try OTPAuthURL.account(from: "otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PX1")
        }
    }

    @Test func rejectsUnknownAlgorithmsDigitsAndPeriods() {
        #expect(throws: OTPAuthURL.ParsingError.unsupportedAlgorithm("MD5")) {
            try OTPAuthURL.account(from: "otpauth://totp/a?secret=JBSWY3DPEHPK3PXP&algorithm=MD5")
        }
        #expect(throws: OTPAuthURL.ParsingError.unsupportedDigits("7")) {
            try OTPAuthURL.account(from: "otpauth://totp/a?secret=JBSWY3DPEHPK3PXP&digits=7")
        }
        #expect(throws: OTPAuthURL.ParsingError.invalidPeriod("0")) {
            try OTPAuthURL.account(from: "otpauth://totp/a?secret=JBSWY3DPEHPK3PXP&period=0")
        }
        #expect(throws: OTPAuthURL.ParsingError.invalidPeriod("soon")) {
            try OTPAuthURL.account(from: "otpauth://totp/a?secret=JBSWY3DPEHPK3PXP&period=soon")
        }
    }

    @Test func ignoresParametersItDoesNotKnow() throws {
        let account = try OTPAuthURL.account(from: "otpauth://totp/a?secret=JBSWY3DPEHPK3PXP&image=x&counter=3")
        #expect(account.secret == secret)
    }
}
