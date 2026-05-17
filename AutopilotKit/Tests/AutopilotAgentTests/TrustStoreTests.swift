import Testing
@testable import AutopilotAgent

struct TrustStoreTests {
    @Test func untrustedByDefault() {
        let store = TrustStore()
        #expect(!store.isTrusted(app: "Music"))
    }

    @Test func sessionTrustIsHonoredCaseInsensitively() {
        var store = TrustStore()
        store.recordSessionTrust(app: "Music")
        #expect(store.isTrusted(app: "music"))
        #expect(store.isTrusted(app: "MUSIC"))
    }

    @Test func permanentTrustIsHonored() {
        let store = TrustStore(permanentlyTrusted: ["Mail"])
        #expect(store.isTrusted(app: "mail"))
        #expect(!store.isTrusted(app: "Music"))
    }

    @Test func sessionTrustIsScopedToOneApp() {
        var store = TrustStore()
        store.recordSessionTrust(app: "Music")
        #expect(!store.isTrusted(app: "Messages"))
    }
}
