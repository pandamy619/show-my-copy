import Testing

@testable import ShowMyCopy

@MainActor
struct CopySourceTests {
    private let textEdit = SourceApp(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")
    private let onePassword = SourceApp(bundleIdentifier: "com.1password.1password", name: "1Password")

    @Test func noAppIsUnknownAndNeverExcluded() {
        var asked = false
        let source = CopySource(app: nil) { _ in
            asked = true
            return true
        }
        #expect(source == .unknown)
        #expect(source.app == nil)
        #expect(!asked)
    }

    @Test func appWithoutBundleIdentifierIsAnOrdinaryApp() {
        let app = SourceApp(bundleIdentifier: nil, name: "Tool")
        let source = CopySource(app: app) { _ in true }
        #expect(source == .app(app))
        #expect(source.app == app)
    }

    @Test func excludedAppIsExcludedAndRecordsNoApp() {
        let source = CopySource(app: textEdit) { $0 == "com.apple.TextEdit" }
        #expect(source == .excluded)
        #expect(source.app == nil)
        #expect(!source.isPasswordManager)
    }

    @Test func exclusionGoesBeforeTheBuiltInPasswordManagers() {
        #expect(CopySource(app: onePassword) { _ in true } == .excluded)
        let notExcluded = CopySource(app: onePassword) { _ in false }
        #expect(notExcluded == .passwordManager(onePassword))
        #expect(notExcluded.isPasswordManager)
        #expect(notExcluded.app == onePassword)
    }

    @Test func otherAppIsAnOrdinaryApp() {
        #expect(CopySource(app: textEdit) { _ in false } == .app(textEdit))
    }
}
