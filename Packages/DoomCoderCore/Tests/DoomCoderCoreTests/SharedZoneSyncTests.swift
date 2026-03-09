import Foundation
import Testing
import CloudKit
@testable import DoomCoderCore

@Suite("Shared-zone sync contract (v3)")
struct SharedZoneSyncTests {

    // MARK: - Per-Mac zone naming

    @Test func perMacZoneNameIsUnique() {
        let a = CloudKitConstants.zoneName(forMacId: "MAC-A")
        let b = CloudKitConstants.zoneName(forMacId: "MAC-B")
        #expect(a == "DoomCoderZone-MAC-A")
        #expect(a != b)
        #expect(CloudKitConstants.schemaVersion == 3)
    }

    // MARK: - DeviceModelName

    @Test func deviceModelMapsKnownIdentifier() {
        #expect(DeviceModelName.marketingName(for: "iPhone17,1") == "iPhone 16 Pro")
        #expect(DeviceModelName.marketingName(for: "iPad16,3").hasPrefix("iPad Pro"))
    }

    @Test func deviceModelFallsBackToFamily() {
        #expect(DeviceModelName.marketingName(for: "iPhone99,9") == "iPhone")
        #expect(DeviceModelName.marketingName(for: "iPad99,9") == "iPad")
        #expect(DeviceModelName.marketingName(for: "Watch9,9") == "Apple Watch")
        #expect(DeviceModelName.marketingName(for: "") == "Device")
    }

    // MARK: - CompanionStatusRecord round-trip

    @Test func companionStatusRoundTripsCustomName() {
        let zid = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName(forMacId: "MAC-A"),
                                  ownerName: "ownerRecord")
        let original = CompanionStatusRecord(
            deviceId: "DEV-1",
            name: "Yash's iPhone",
            model: "iPhone 17 Pro",
            systemVersion: "iOS 26.0",
            appVersion: "3.0.0",
            customDeviceName: "Yash's iPhone"
        )
        let ck = original.toCKRecord(in: zid)
        // recordID is addressed into the target Mac's zone (owner preserved).
        #expect(ck.recordID.zoneID == zid)
        #expect(ck.recordID.recordName == "CompanionStatus-DEV-1")

        let decoded = CompanionStatusRecord(ck)
        #expect(decoded != nil)
        #expect(decoded?.customDeviceName == "Yash's iPhone")
        #expect(decoded?.model == "iPhone 17 Pro")
        #expect(decoded?.displayName == "Yash's iPhone")
    }

    @Test func companionDisplayNameFallsBackToModel() {
        let r = CompanionStatusRecord(
            deviceId: "DEV-2", name: "iPhone", model: "iPhone 17",
            systemVersion: "iOS 26", appVersion: "3", customDeviceName: ""
        )
        #expect(r.displayName == "iPhone 17")
    }

    // MARK: - Owner vs participant zone addressing

    @Test func recordIDsTargetTheGivenZone() {
        let ownerZone = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName(forMacId: "MAC-A"),
                                        ownerName: CKCurrentUserDefaultName)
        let participantZone = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName(forMacId: "MAC-A"),
                                              ownerName: "macOwnerRecordName")

        let mac = MacStatusRecord(macId: "MAC-A", name: "Studio", version: "3.0.0",
                                  sleepActive: true, mode: "screenOn")
        #expect(mac.recordID(in: ownerZone).zoneID == ownerZone)

        let cmd = ControlCommandRecord(targetMacId: "MAC-A", issuerDeviceId: "DEV-1",
                                       verb: .setKeepAwakeMode, value: "on")
        // Participant addresses its write into the Mac's (owner's) zone.
        #expect(cmd.recordID(in: participantZone).zoneID == participantZone)
        #expect(cmd.toCKRecord(in: participantZone).recordID.zoneID.ownerName == "macOwnerRecordName")
    }
}
