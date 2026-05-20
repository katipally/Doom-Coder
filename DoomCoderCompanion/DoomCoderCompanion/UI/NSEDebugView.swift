// NSEDebugView.swift — DoomCoder Companion
// Shows the raw CloudKit push payload last received by the Notification
// Service Extension (written to App Group as nse_debug.json). Use this to
// verify the "ck.qry.af" structure and confirm which desiredKeys arrive.
// Remove this tab (and the dumpPayload() call in NotificationService) once
// rich notifications are confirmed working end-to-end.

import SwiftUI
import DoomCoderCore

struct NSEDebugView: View {

    @State private var payload: String = "No NSE payload yet.\n\nTrigger a Mac agent event or use  Mac Settings → Send Test Ping.\n\nThe payload appears here after the next push is received."
    @State private var lastLoaded: Date?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let d = lastLoaded {
                        Text("Last updated: \(d.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(payload)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .navigationTitle("NSE Payload Debug")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Reload") { load() }
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        guard let dir = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier:
                            CloudKitConstants.appGroupIdentifier),
              let data = try? Data(contentsOf: dir.appendingPathComponent("nse_debug.json")),
              let str = String(data: data, encoding: .utf8) else {
            return
        }
        payload = str
        lastLoaded = Date()
    }
}
