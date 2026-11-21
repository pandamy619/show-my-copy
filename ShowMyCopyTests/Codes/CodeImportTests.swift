import Foundation
import Testing

@testable import ShowMyCopy

struct CodeImportTests {
    @Test func readsAnAddress() throws {
        let outcome = try CodeImport.parse(CodeFixtures.addressURL)
        #expect(outcome.accounts == [CodeFixtures.account()])
        #expect(outcome.skipped.isEmpty)
        #expect(outcome.batchIndex == nil)
    }

    @Test func readsAnExportWithItsBatch() throws {
        let outcome = try CodeImport.parse("  \(CodeFixtures.exportURL)\n")
        #expect(outcome.accounts.map(\.displayName) == ["Example (alice@google.com)"])
        #expect(outcome.batchIndex == 0)
        #expect(outcome.batchSize == 1)
    }

    @Test func readsSeveralAddressesOnSeparateLines() throws {
        let outcome = try CodeImport.parse("\(CodeFixtures.addressURL)\n\n\(CodeFixtures.exportURL)\n")
        #expect(outcome.accounts.map(\.issuer) == ["GitHub", "Example"])
    }

    @Test func readsABareKeyWithTheNamesTypedNextToIt() throws {
        let outcome = try CodeImport.parse("jbsw y3dp ehpk 3pxp", issuer: " GitHub ", name: "octocat")
        let account = try #require(outcome.accounts.first)
        #expect(account.issuer == "GitHub")
        #expect(account.name == "octocat")
        #expect(account.secret == Data("Hello!".utf8) + Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(account.algorithm == .sha1)
        #expect(account.digits == .six)
        #expect(account.period == 30)
    }

    @Test func aKeyOnSeveralLinesIsOneKey() throws {
        let outcome = try CodeImport.parse("JBSWY3DP\nEHPK3PXP", issuer: "GitHub")
        #expect(outcome.accounts.first?.secret == Data("Hello!".utf8) + Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test func aBareKeyNeedsAName() {
        #expect(throws: CodeImport.Failure.keyNeedsName) {
            try CodeImport.parse("JBSWY3DPEHPK3PXP", issuer: "  ", name: "")
        }
    }

    @Test(arguments: ["", "  \n "])
    func emptyTextIsEmpty(text: String) {
        #expect(throws: CodeImport.Failure.empty) {
            try CodeImport.parse(text, issuer: "GitHub")
        }
    }

    @Test func textThatIsNeitherIsNotAKey() {
        #expect(throws: CodeImport.Failure.key(.invalidCharacter(","))) {
            try CodeImport.parse("hello, world!", issuer: "GitHub")
        }
    }

    @Test func aBrokenAddressReportsWhy() {
        #expect(throws: CodeImport.Failure.address(.missingSecret)) {
            try CodeImport.parse("otpauth://totp/GitHub:octocat?issuer=GitHub")
        }
        #expect(throws: CodeImport.Failure.address(.unsupportedType("hotp"))) {
            try CodeImport.parse("otpauth://hotp/GitHub:octocat?secret=JBSWY3DPEHPK3PXP")
        }
        #expect(throws: CodeImport.Failure.export(.missingData)) {
            try CodeImport.parse("otpauth-migration://offline")
        }
    }

    @Test func onlyTheSchemesItReadsAreAddresses() {
        #expect(CodeImport.isAddress("OTPAUTH://totp/a?secret=JBSWY3DPEHPK3PXP"))
        #expect(CodeImport.isAddress("otpauth-migration://offline?data=Cg=="))
        #expect(!CodeImport.isAddress("https://example.com"))
        #expect(!CodeImport.isAddress("JBSWY3DPEHPK3PXP"))
    }
}
