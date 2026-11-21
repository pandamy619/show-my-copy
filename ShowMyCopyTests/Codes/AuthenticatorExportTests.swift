import Foundation
import Testing

@testable import ShowMyCopy

struct AuthenticatorExportTests {
    private let helloSecret = Data("Hello!".utf8) + Data([0xDE, 0xAD, 0xBE, 0xEF])

    /// One account, as Google Authenticator exports it (checked against another decoder).
    private let singleAccountURL =
        "otpauth-migration://offline?data=CjEKCkhlbGxvId6tvu8SGEV4YW1wbGU6YWxpY2VAZ29vZ2xlLmNvbRoHRXhhbXBsZTAC"

    @Test func decodesASingleAccount() throws {
        let export = try AuthenticatorExport.decode(singleAccountURL)
        #expect(export.accounts.count == 1)
        #expect(export.skipped.isEmpty)
        #expect(export.batchIndex == 0)
        #expect(export.batchSize == 1)
        let account = try #require(export.accounts.first)
        #expect(account.issuer == "Example")
        #expect(account.name == "alice@google.com")
        #expect(account.secret == helloSecret)
        #expect(account.algorithm == .sha1)
        #expect(account.digits == .six)
        #expect(account.period == 30)
        #expect(TOTP.code(for: account, at: Date(timeIntervalSince1970: 59)).digits == "996554")
    }

    /// Three accounts in the second of two QR codes: the one above, a SHA-256 8-digit one, a counter-based one that
    /// cannot be imported, and fields the app does not know.
    private let secondBatchURL =
        "otpauth-migration://offline?data=CjEKCkhlbGxvId6tvu8SGEV4YW1wbGU6YWxpY2VAZ29vZ2xlLmNvbRoHRXhhbXBsZTACCjMKIDEy"
        + "MzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDEyEgNib2IaBEJhbmsgAigCMAIKIwoUMTIzNDU2Nzg5MDEyMzQ1Njc4OTASB2NvdW50"
        + "ZXIwATgFEAEYAiABKLlgSQEBAQEBAQEBVQICAgI%3D"

    @Test func decodesABatchWithSeveralAccountsAndSkipsWhatItCannotImport() throws {
        let export = try AuthenticatorExport.decode(secondBatchURL)
        #expect(export.batchIndex == 1)
        #expect(export.batchSize == 2)
        #expect(export.accounts.map(\.displayName) == ["Example (alice@google.com)", "Bank (bob)"])
        let bank = export.accounts[1]
        #expect(bank.secret == Data("12345678901234567890123456789012".utf8))
        #expect(bank.algorithm == .sha256)
        #expect(bank.digits == .eight)
        #expect(TOTP.code(for: bank, at: Date(timeIntervalSince1970: 0)).digits == "18920136")
        #expect(export.skipped == [SkippedAccount(issuer: "", name: "counter", reason: .counterBased)])
    }

    @Test func acceptsUnpaddedAndURLSafeBase64() throws {
        let unpadded = secondBatchURL.replacingOccurrences(of: "%3D", with: "")
        #expect(try AuthenticatorExport.decode(unpadded) == (try AuthenticatorExport.decode(secondBatchURL)))
        let urlSafe = secondBatchURL.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        #expect(try AuthenticatorExport.decode(urlSafe) == (try AuthenticatorExport.decode(secondBatchURL)))
    }

    @Test func theIssuerIsKeptOnceWhenItIsAlsoThePrefixOfTheName() throws {
        let export = try AuthenticatorExport.decode(
            payload: ProtobufWriter().message(
                1, ProtobufWriter().bytes(1, helloSecret).string(2, "GitHub:octocat").string(3, "GitHub")
            ).data)
        #expect(export.accounts.map(\.issuer) == ["GitHub"])
        #expect(export.accounts.map(\.name) == ["octocat"])
    }

    @Test func aNameWithADifferentPrefixIsKeptWhole() throws {
        let export = try AuthenticatorExport.decode(
            payload: ProtobufWriter().message(
                1, ProtobufWriter().bytes(1, helloSecret).string(2, "work:octocat").string(3, "GitHub")
            ).data)
        #expect(export.accounts.map(\.issuer) == ["GitHub"])
        #expect(export.accounts.map(\.name) == ["work:octocat"])
    }

    @Test func unspecifiedAlgorithmDigitsAndTypeMeanTheDefaults() throws {
        let export = try AuthenticatorExport.decode(
            payload: ProtobufWriter().message(1, ProtobufWriter().bytes(1, helloSecret).string(2, "a")).data)
        let account = try #require(export.accounts.first)
        #expect(account.algorithm == .sha1)
        #expect(account.digits == .six)
    }

    @Test func skipsAccountsWithAnUnknownAlgorithmOrDigitsOrNoSecret() throws {
        let export = try AuthenticatorExport.decode(
            payload: ProtobufWriter()
                .message(1, ProtobufWriter().bytes(1, helloSecret).string(2, "md5").varint(4, 4))
                .message(1, ProtobufWriter().bytes(1, helloSecret).string(2, "digits").varint(5, 3))
                .message(1, ProtobufWriter().string(2, "empty").string(3, "Issuer"))
                .data)
        #expect(export.accounts.isEmpty)
        #expect(
            export.skipped == [
                SkippedAccount(issuer: "", name: "md5", reason: .unsupportedAlgorithm),
                SkippedAccount(issuer: "", name: "digits", reason: .unsupportedDigits),
                SkippedAccount(issuer: "Issuer", name: "empty", reason: .emptySecret),
            ])
    }

    @Test(arguments: [
        "otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP", "https://example.com/?data=Cg==", "", "offline",
    ])
    func rejectsOtherAddresses(text: String) {
        #expect(throws: AuthenticatorExport.DecodingError.notAnExportURL) {
            try AuthenticatorExport.decode(text)
        }
    }

    @Test(arguments: [
        "otpauth-migration://offline", "otpauth-migration://offline?data=", "otpauth-migration://offline?x=1",
    ])
    func rejectsAMissingPayload(text: String) {
        #expect(throws: AuthenticatorExport.DecodingError.missingData) {
            try AuthenticatorExport.decode(text)
        }
    }

    @Test func rejectsAPayloadThatIsNotBase64() {
        #expect(throws: AuthenticatorExport.DecodingError.invalidData) {
            try AuthenticatorExport.decode("otpauth-migration://offline?data=not*base64!")
        }
    }

    @Test func rejectsATruncatedPayload() {
        // Field 1, 49 bytes promised, none given.
        #expect(throws: AuthenticatorExport.DecodingError.malformed(.truncated)) {
            try AuthenticatorExport.decode("otpauth-migration://offline?data=CjE=")
        }
    }

    @Test func anEmptyPayloadIsAnEmptyExport() throws {
        let export = try AuthenticatorExport.decode(payload: Data())
        #expect(export == AuthenticatorExport(accounts: [], skipped: [], batchIndex: 0, batchSize: 1))
    }
}
