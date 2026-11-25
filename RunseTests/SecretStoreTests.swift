import RunseCore
import XCTest

final class SecretStoreTests: XCTestCase {
    func testInMemorySecretStoreSaveLoadDelete() async throws {
        let store = InMemorySecretStore()
        try await store.save("secret", service: "svc", account: "acct")
        let saved = try await store.load(service: "svc", account: "acct")
        XCTAssertEqual(saved, "secret")
        try await store.delete(service: "svc", account: "acct")
        let deleted = try await store.load(service: "svc", account: "acct")
        XCTAssertNil(deleted)
    }

    func testSharedKeychainAccessGroupUsesBundlePrefixAndSharedSuffix() {
        let accessGroup = KeychainAccessGroup.make(appIdentifierPrefix: "TEAMID1234.")
        XCTAssertEqual(accessGroup, "TEAMID1234.com.yonghuxieyi.zhiyin.keychain")
    }

    func testProviderAPIKeyServiceConstant() {
        // Provider keys live in the keychain under one service name; the app
        // and the extension must agree on it.
        XCTAssertEqual(KeychainStore.providerAPIKeyService, "Zhiyin.ProviderAPIKey")
    }
}
