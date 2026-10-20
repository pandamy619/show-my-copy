import Testing

@testable import ShowMyCopy

struct AppLaunchTests {
    @Test func appModuleIsTestable() {
        #expect(ShowMyCopyApp.self == ShowMyCopyApp.self)
    }
}
