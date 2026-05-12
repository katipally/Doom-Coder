import ActivityKit
import Foundation

struct DoomCoderActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: String
        var currentTool: String?
        var toolCount: Int
        var elapsedSec: Int
        var approvalPending: Bool
        var toolArgsPreview: String?
        var requestId: String?
        var toolDetail: String?
    }

    var sessionKey: String
    var agent: String
    var cwdBasename: String
    var agentColorHex: String
}
