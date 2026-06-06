import Testing
import Foundation
@testable import DoomCoderCore

#if canImport(CloudKit)
import CloudKit

@Suite("DeviceRecord")
struct DeviceRecordTests {
    @Test func macRoundTripsThroughCKRecord() {
        let original = DeviceRecord(
            deviceId: "MAC123",
            role: .mac,
            displayName: "Yash's MacBook Pro",
            model: "MacBookPro18,3",
            osVersion: "macOS 26.0",
            appVersion: "2.8.0 (14)",
            accountName: "Yashwanth",
            accountEmail: "y@icloud.com",
            sleepActive: false,
            mode: "screenOn",
            thermalState: "Normal",
            macAddress: "aa:bb:cc:dd:ee:ff",
            broadcastIPv4: "192.168.1.255"
        )
        let ck = original.toCKRecord()
        #expect(ck.recordType == DeviceRecord.recordType)
        #expect(ck.recordID.recordName == "Device-MAC123")
        let decoded = DeviceRecord(ck)
        #expect(decoded == original)
    }

    @Test func iosRoundTripsWithBattery() {
        let original = DeviceRecord(
            deviceId: "IOS456",
            role: .ios,
            displayName: "Yash's iPhone",
            model: "iPhone 15 Pro",
            osVersion: "iOS 19.0",
            appVersion: "2.8.0 (14)",
            battery: 0.72
        )
        let decoded = DeviceRecord(original.toCKRecord())
        #expect(decoded?.battery == 0.72)
        #expect(decoded?.role == .ios)
        #expect(decoded?.sleepActive == nil)
    }

    @Test func sharedZoneRecordIdUsesOwner() {
        let r = DeviceRecord(deviceId: "IOS456", role: .ios, displayName: "x",
                             model: "", osVersion: "", appVersion: "")
        let id = r.recordID(zoneOwner: "_macOwnerRecordName")
        #expect(id.zoneID.ownerName == "_macOwnerRecordName")
        #expect(id.recordName == "Device-IOS456")
    }
}
#endif

@Suite("DerivedDeviceState")
struct DerivedDeviceStateTests {
    @Test func noPairingIsDisconnected() {
        #expect(DerivedDeviceState.derive(hasPairing: false, peer: nil) == .disconnected)
    }

    @Test func pairingButNoPeerRecordIsPending() {
        #expect(DerivedDeviceState.derive(hasPairing: true, peer: nil) == .pending)
    }

    @Test func freshHeartbeatIsActive() {
        let peer = DeviceRecord(deviceId: "d", role: .ios, displayName: "x",
                                model: "", osVersion: "", appVersion: "",
                                lastSeen: Date())
        #expect(DerivedDeviceState.derive(hasPairing: true, peer: peer) == .active)
    }

    @Test func staleHeartbeatIsOffline() {
        let old = Date().addingTimeInterval(-600)
        let peer = DeviceRecord(deviceId: "d", role: .ios, displayName: "x",
                                model: "", osVersion: "", appVersion: "",
                                lastSeen: old)
        #expect(DerivedDeviceState.derive(hasPairing: true, peer: peer) == .offline)
    }
}
