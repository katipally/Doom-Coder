// SharedToolUI.swift — Doom Coder Companion (Tools)
// Small reusable UI pieces shared across the Tools views.

import SwiftUI
import UIKit

/// A simple empty-state used inside Tools lists. Never a dead end.
struct ToolEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var secondaryActionTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title).font(.title3.bold())
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                if let actionTitle, let action {
                    Button(actionTitle) {
                        Haptics.tap()
                        action()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                if let secondaryActionTitle, let secondaryAction {
                    Button(secondaryActionTitle) {
                        Haptics.tap()
                        secondaryAction()
                    }
                    .font(.subheadline.weight(.medium))
                }
            }
            .padding(.top, 2)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}
