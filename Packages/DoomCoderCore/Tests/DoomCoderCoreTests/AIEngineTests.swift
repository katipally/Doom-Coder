import Foundation
import Testing
@testable import DoomCoderCore

@Suite("AIResult")
struct AIResultTests {
    @Test func actionableFailuresAreClassified() {
        #expect(AIFailure.network("x").isActionable == true)
        #expect(AIFailure.missingKey.isActionable == true)
        #expect(AIFailure.rateLimited.isActionable == true)
        #expect(AIFailure.malformed.isActionable == false)
        #expect(AIFailure.safetyRefusal.isActionable == false)
        #expect(AIFailure.unavailable(.deviceNotEligible).isActionable == false)
    }
}

@Suite("AIEngineSelection")
struct AIEngineSelectionTests {
    @Test func exposesExactlyOnDeviceAndRemoteKey() {
        #expect(AIEngineSelection.allCases == [.appleOnDevice, .remoteKey])
    }

    @Test func tiersAreOnDeviceAndRemoteKey() {
        #expect(Set(AITier.allCases) == [.appleOnDevice, .remoteKey])
    }
}
