import Foundation
import Testing
@testable import DoomCoderCore

@Suite("Keychain round-trip")
struct KeychainTests {

    /// Use a unique service per test so we never collide with a real
    /// keychain entry. Tests share the device's actual Keychain
    /// because there's no in-memory shim available without a
    /// security framework rewrite; each test cleans up after itself.
    private func uniqueService() -> String {
        "com.doomcoder.tests.keychain.\(UUID().uuidString)"
    }

    @Test func setThenGetRoundTripsValue() {
        let service = uniqueService()
        defer { Keychain.delete(account: "roundtrip", service: service) }
        Keychain.set("sk-test-123", account: "roundtrip", service: service)
        #expect(Keychain.get(account: "roundtrip", service: service) == "sk-test-123")
    }

    @Test func getReturnsNilForMissingKey() {
        #expect(Keychain.get(account: "missing", service: uniqueService()) == nil)
    }

    @Test func setOverwritesExistingValue() {
        let service = uniqueService()
        defer { Keychain.delete(account: "overwrite", service: service) }
        Keychain.set("v1", account: "overwrite", service: service)
        Keychain.set("v2", account: "overwrite", service: service)
        #expect(Keychain.get(account: "overwrite", service: service) == "v2")
    }

    @Test func deleteRemovesValue() {
        let service = uniqueService()
        Keychain.set("to-delete", account: "rm", service: service)
        Keychain.delete(account: "rm", service: service)
        #expect(Keychain.get(account: "rm", service: service) == nil)
    }

    @Test func differentServicesAreIsolated() {
        let serviceA = uniqueService()
        let serviceB = uniqueService()
        defer {
            Keychain.delete(account: "shared", service: serviceA)
            Keychain.delete(account: "shared", service: serviceB)
        }
        Keychain.set("inA", account: "shared", service: serviceA)
        Keychain.set("inB", account: "shared", service: serviceB)
        #expect(Keychain.get(account: "shared", service: serviceA) == "inA")
        #expect(Keychain.get(account: "shared", service: serviceB) == "inB")
    }

    @Test func emptyValueIsStored() {
        let service = uniqueService()
        defer { Keychain.delete(account: "empty", service: service) }
        // The default set/get tolerates an empty string (it stores the
        // empty Data, then reads it back as an empty String). We document
        // this behavior: callers should check for emptiness before
        // using the value.
        Keychain.set("", account: "empty", service: service)
        let value = Keychain.get(account: "empty", service: service)
        #expect(value == "")
    }
}
