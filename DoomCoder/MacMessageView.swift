import SwiftUI
import AppKit
import DoomCoderCore

// MARK: - MacMessageView
//
// Renders one transcript message in the Prompts pane: user requests
// as trailing glass bubbles, the AI's refined prompt as plain
// leading text under a "Refined prompt" header with a Copy action,
// and failures inline with Retry.
struct MacMessageView: View {
    let message: ChatMessage
    let onCopy: () -> Void
    let onRetry: () -> Void
    let onEdit: () -> Void

    var body: some View {
        switch message.role {
        case .user: userBubble
        case .assistant: assistantContent
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            Text(message.text)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular.tint(.accentColor.opacity(0.18)), in: .rect(cornerRadius: 18))
                .contextMenu {
                    Button { onEdit() } label: { Label("Edit & resend", systemImage: "pencil") }
                    Button { MacClipboard.copy(message.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("You said: \(message.text)")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch message.status {
            case .streaming:
                if message.trimmedText.isEmpty {
                    refiningHeader
                } else {
                    header("Refined prompt")
                    Text(message.text).font(.body).textSelection(.enabled)
                }
            case .complete:
                header("Refined prompt")
                Text(message.text).font(.body).textSelection(.enabled)
                Button { onCopy() } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.glass)
                .clipShape(.capsule)
                .padding(.top, 2)
                .accessibilityHint("Copies the refined prompt to the clipboard")
            case .failed, .cancelled:
                failureView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var refiningHeader: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Refining…").font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityLabel("Refining your prompt")
    }

    private func header(_ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.tint)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let tier = message.tier {
                Text("· \(tier.shortName)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var failureView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message.errorText ?? "Something went wrong.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button { onRetry() } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.glass)
            .clipShape(.capsule)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}
