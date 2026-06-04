// PairSuccessView.swift — DoomCoder Companion
// Post-pairing success sheet showing the Mac name and a Done button. Shown
// after a doomcoder:// pair URL or QR scan completes successfully.

import SwiftUI
import DoomCoderCore

struct PairSuccessView: View {
    let message: String
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text(message)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Spacer()
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
        .padding(32)
    }
}
