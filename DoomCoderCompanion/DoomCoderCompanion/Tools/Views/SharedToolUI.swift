// SharedToolUI.swift — DoomCoder Companion (Tools)
// Small reusable UI pieces shared across the Tools views.

import SwiftUI
import UIKit

/// A button that copies text to the clipboard and briefly confirms with a
/// checkmark + success haptic. Works the same everywhere copy is offered.
struct CopyButton: View {
    let text: String
    var title: String = "Copy"
    var prominent: Bool = false

    @State private var copied = false

    private func copy() {
        UIPasteboard.general.string = text
        Haptics.success()
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.snappy) { copied = false }
        }
    }

    private var label: some View {
        Label(copied ? "Copied" : title,
              systemImage: copied ? "checkmark" : "doc.on.doc")
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: prominent ? .infinity : nil)
            .padding(.vertical, prominent ? 4 : 0)
    }

    var body: some View {
        Group {
            if prominent {
                Button(action: copy) { label }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button(action: copy) { label }
                    .buttonStyle(.bordered)
            }
        }
        .disabled(text.isEmpty)
        .accessibilityLabel(copied ? "Copied to clipboard" : "\(title) to clipboard")
    }
}

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
