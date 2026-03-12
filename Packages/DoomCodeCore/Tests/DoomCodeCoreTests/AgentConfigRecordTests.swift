import Foundation
import Testing
import CloudKit
@testable import DoomCodeCore

@Suite("AgentConfigRecord contract")
struct AgentConfigRecordTests {

    @Test func emptyStatusesYieldsEmptyDictionary() {
        let r = AgentConfigRecord(macId: "MAC-1", agents: [], statuses: "")
        #expect(r.agentStatuses.isEmpty)
    }

    @Test func typedInitializerEncodesJSON() {
        let r = AgentConfigRecord(
            macId: "MAC-1",
            agents: ["claude"],
            agentStatuses: ["claude": "running", "cursor": "waiting"]
        )
        #expect(!r.statuses.isEmpty)
        // The JSON must round-trip back to the same dictionary.
        #expect(r.agentStatuses == ["claude": "running", "cursor": "waiting"])
    }

    @Test func malformedStatusesYieldsEmptyDictionary() {
        // Pre-existing data with non-dict JSON (e.g. an array accidentally
        // stored) should not crash — it should resolve to an empty dict so
        // the UI can degrade gracefully.
        let r = AgentConfigRecord(macId: "MAC-1", agents: [], statuses: "[\"unexpected\"]")
        #expect(r.agentStatuses.isEmpty)
    }

    @Test func recordRoundTripPreservesStatuses() {
        let zone = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName(forMacId: "MAC-1"),
                                   ownerName: CKCurrentUserDefaultName)
        let original = AgentConfigRecord(
            macId: "MAC-1",
            agents: ["claude", "cursor"],
            agentStatuses: ["claude": "completed"]
        )
        let ck = original.toCKRecord(in: zone)
        #expect(ck["statuses"] as? String == original.statuses)
    }
}
