import SwiftUI

// PayloadRendererView — clean, human-readable render of any hook payload JSON.
// Replaces the raw monospace JSON dump in LogsView and LiveEventRow.
//
// Features:
//   • Content fields (prompt, response, message…) → framed scrollable text bubble
//   • Command/script fields → monospaced code block with background
//   • Nested dicts → collapsible indented sub-section with left accent border
//   • Arrays → collapsible bullet/numbered list
//   • Error fields → red-tinted text
//   • Metadata (session IDs, pids) → dimmed, rendered last
//   • "Raw JSON" ↔ "Clean View" toggle button
//   • "Copy" button always present

struct PayloadRendererView: View {
    let json: String

    @State private var showRawJSON = false
    @State private var fields: [ParsedField] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            actionBar

            if showRawJSON {
                rawJSONView
                    .transition(.opacity)
            } else {
                cleanView
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .onAppear { fields = parsePayload(json) }
        .onChange(of: json) { _, _ in fields = parsePayload(json) }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            Spacer()
            Button {
                withAnimation(DCAnim.micro) { showRawJSON.toggle() }
            } label: {
                Label(showRawJSON ? "Clean View" : "Raw JSON",
                      systemImage: showRawJSON ? "text.alignleft" : "curlybraces")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prettyJSON(json), forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: - Raw JSON fallback

    private var rawJSONView: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(prettyJSON(json))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.vertical, 2)
        }
        .frame(maxHeight: 220)
    }

    // MARK: - Clean rendered view

    private var cleanView: some View {
        Group {
            if fields.isEmpty {
                Text("(empty payload)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(fields) { field in
                        FieldView(field: field, depth: 0)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8)
        else { return raw }
        return str
    }
}

// MARK: - Data model

/// A single parsed field, ready to render.
struct ParsedField: Identifiable {
    let id = UUID()
    let key: String
    let displayKey: String
    let value: FieldValue
    let kind: FieldKind
}

enum FieldKind {
    case content        // long text → scrollable text bubble
    case code           // command/script → monospace code block
    case path           // file path → 📄 prefix in value
    case errorField     // error fields → red tint
    case metadata       // IDs, pids, synthetic → dimmed, shown last
    case tool           // tool_name → accent label
    case normal         // standard key-value row
}

/// Recursive value type. `indirect` breaks the mutual reference cycle with ParsedField.
indirect enum FieldValue {
    case string(String)
    case number(String)     // pre-formatted for display
    case bool(Bool)
    case dict([ParsedField])
    case array([FieldValue])
    case null
}

// MARK: - Field categorization sets

private let contentKeys: Set<String> = [
    "prompt", "message", "response", "content", "text", "output",
    "tool_result", "result", "notification_message", "body",
    "error_message", "description", "summary", "reasoning", "thinking",
    "completion", "assistant_message", "user_message", "input_text",
    "rendered_text", "detail",
]

private let codeKeys: Set<String> = [
    "command", "script", "code", "shell_command", "command_line",
    "bash_command", "shell", "cmd",
]

private let pathKeys: Set<String> = [
    "file_path", "path", "cwd", "file", "filename", "directory", "dir",
    "working_directory", "workspace", "absolute_path", "relative_path",
]

private let errorKeys: Set<String> = [
    "error", "error_type", "signal", "stack_trace", "exception",
    "stderr", "error_code",
]

private let metadataKeys: Set<String> = [
    "session_id", "conversation_id", "trajectory_id", "execution_id",
    "generation_id", "sessionId", "pid", "ts", "synthetic", "demo", "v",
    "request_id", "trace_id", "correlation_id", "id", "uuid",
]

private let toolKeys: Set<String> = ["tool_name", "tool", "mcp_tool_name"]

// MARK: - Payload parser

func parsePayload(_ json: String) -> [ParsedField] {
    guard let data = json.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return [] }

    var content: [ParsedField] = []
    var toolFields: [ParsedField] = []
    var codeFields: [ParsedField] = []
    var pathFields: [ParsedField] = []
    var errorFields: [ParsedField] = []
    var normalFields: [ParsedField] = []
    var dictArrayFields: [ParsedField] = []
    var metadataFields: [ParsedField] = []

    for (key, anyVal) in obj {
        let kind = fieldKind(for: key, value: anyVal)
        let field = ParsedField(
            key: key,
            displayKey: humanReadableKey(key),
            value: makeFieldValue(from: anyVal),
            kind: kind
        )
        switch field.value {
        case .dict, .array:
            dictArrayFields.append(field)
        default:
            switch kind {
            case .content:    content.append(field)
            case .tool:       toolFields.append(field)
            case .code:       codeFields.append(field)
            case .path:       pathFields.append(field)
            case .errorField: errorFields.append(field)
            case .metadata:   metadataFields.append(field)
            case .normal:     normalFields.append(field)
            }
        }
    }

    // Render order: content → tool → code → path → error → normal → dicts/arrays → metadata
    let sorted = [content, toolFields, codeFields, pathFields, errorFields, normalFields, dictArrayFields, metadataFields]
        .flatMap { $0.sorted { $0.key < $1.key } }
    return sorted
}

private func fieldKind(for key: String, value: Any) -> FieldKind {
    let lk = key.lowercased()
    if toolKeys.contains(lk)     { return .tool }
    if codeKeys.contains(lk)     { return .code }
    if pathKeys.contains(lk)     { return .path }
    if errorKeys.contains(lk)    { return .errorField }
    // exit_code is an error only when non-zero
    if lk == "exit_code", let n = value as? Int, n != 0 { return .errorField }
    if metadataKeys.contains(lk) { return .metadata }
    if contentKeys.contains(lk)  { return .content }
    // Heuristic: any long string is probably content
    if let s = value as? String, s.count > 80 { return .content }
    return .normal
}

private func makeFieldValue(from value: Any) -> FieldValue {
    if let b = value as? Bool     { return .bool(b) }
    if let s = value as? String   { return .string(s) }
    if let n = value as? Int      { return .number(String(n)) }
    if let n = value as? Double   { return .number(String(format: "%.4g", n)) }
    if let d = value as? [String: Any] {
        let sub = d.map { k, v in
            ParsedField(
                key: k,
                displayKey: humanReadableKey(k),
                value: makeFieldValue(from: v),
                kind: fieldKind(for: k, value: v)
            )
        }.sorted { $0.key < $1.key }
        return .dict(sub)
    }
    if let a = value as? [Any] {
        return .array(a.map { makeFieldValue(from: $0) })
    }
    if value is NSNull { return .null }
    return .string(String(describing: value))
}

private func humanReadableKey(_ key: String) -> String {
    key.replacingOccurrences(of: "_", with: " ")
}

// MARK: - FieldView

struct FieldView: View {
    let field: ParsedField
    let depth: Int

    @State private var expanded: Bool
    @State private var textExpanded = false

    init(field: ParsedField, depth: Int) {
        self.field = field
        self.depth = depth
        // Auto-expand dicts/arrays at depth 0 so the user sees everything immediately
        let isComplex: Bool
        switch field.value {
        case .dict, .array: isComplex = true
        default:            isComplex = false
        }
        _expanded = State(initialValue: isComplex && depth == 0)
    }

    var body: some View {
        switch field.value {
        case .string(let s):
            stringFieldView(s)
        case .number(let n):
            keyValueRow(value: n)
        case .bool(let b):
            keyValueRow(value: b ? "✅  true" : "❌  false")
        case .null:
            keyValueRow(value: "null")
        case .dict(let subFields):
            dictFieldView(subFields)
        case .array(let items):
            arrayFieldView(items)
        }
    }

    // MARK: String field

    @ViewBuilder
    private func stringFieldView(_ value: String) -> some View {
        switch field.kind {
        case .content:
            VStack(alignment: .leading, spacing: 3) {
                keyLabel
                contentBubble(text: value)
            }
        case .code:
            VStack(alignment: .leading, spacing: 3) {
                keyLabel
                codeBlock(text: value)
            }
        case .path:
            keyValueRow(value: "📄  " + value)
        default:
            keyValueRow(value: value)
        }
    }

    // MARK: Content bubble (long text)

    @ViewBuilder
    private func contentBubble(text: String) -> some View {
        let isLong = text.count > 300
        let displayText = (!textExpanded && isLong) ? String(text.prefix(300)) + "…" : text
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.vertical, showsIndicators: isLong && textExpanded) {
                Text(displayText)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: textExpanded ? 300 : 120)
            .background(Color.accentColor.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5)
            )
            if isLong {
                Button {
                    withAnimation(DCAnim.micro) { textExpanded.toggle() }
                } label: {
                    Text(textExpanded ? "Show less" : "Show more (\(text.count) chars)")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Code block

    @ViewBuilder
    private func codeBlock(text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: Dict field

    @ViewBuilder
    private func dictFieldView(_ subFields: [ParsedField]) -> some View {
        if subFields.isEmpty {
            keyValueRow(value: "{}")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    withAnimation(DCAnim.snap) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Text(field.displayKey)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("{ \(subFields.count) }")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                if expanded {
                    if depth < 3 {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(subFields) { sub in
                                FieldView(field: sub, depth: depth + 1)
                            }
                        }
                        .padding(.leading, 10)
                        .padding(.vertical, 6)
                        .padding(.trailing, 4)
                        .background(Color.secondary.opacity(0.04))
                        .overlay(
                            HStack(spacing: 0) {
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.35))
                                    .frame(width: 2)
                                Spacer()
                            }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        Text("(nested too deep — use Raw JSON)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 12)
                    }
                }
            }
        }
    }

    // MARK: Array field

    @ViewBuilder
    private func arrayFieldView(_ items: [FieldValue]) -> some View {
        if items.isEmpty {
            keyValueRow(value: "[]")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    withAnimation(DCAnim.snap) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Text(field.displayKey)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("[\(items.count)]")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                if expanded {
                    let capped = Array(items.prefix(10))
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(capped.enumerated()), id: \.offset) { _, item in
                            arrayItemRow(item)
                        }
                        if items.count > 10 {
                            Text("… \(items.count - 10) more items")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 4)
                        }
                    }
                    .padding(.leading, 10)
                    .padding(.vertical, 6)
                    .padding(.trailing, 4)
                    .background(Color.secondary.opacity(0.04))
                    .overlay(
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.3))
                                .frame(width: 2)
                            Spacer()
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder
    private func arrayItemRow(_ value: FieldValue) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
            switch value {
            case .string(let s):
                Text(s)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            case .number(let n):
                Text(n)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.primary)
            case .bool(let b):
                Text(b ? "✅  true" : "❌  false")
                    .font(.caption2)
            case .null:
                Text("null")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .dict(let subFields):
                if depth < 3 {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(subFields) { sub in
                            FieldView(field: sub, depth: depth + 1)
                        }
                    }
                } else {
                    Text("{…}")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            case .array:
                Text("[…]")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Key label (standalone, used above content/code fields)

    private var keyLabel: some View {
        Text(field.displayKey)
            .font(.caption2.weight(.medium))
            .foregroundStyle(labelColor)
    }

    // MARK: Simple key-value row

    @ViewBuilder
    private func keyValueRow(value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(field.displayKey)
                .font(.caption2.weight(field.kind == .tool ? .semibold : .regular))
                .foregroundStyle(labelColor)
                .frame(width: 110, alignment: .leading)
                .lineLimit(2)
            Text(value)
                .font(.caption2)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
    }

    // MARK: Colors

    private var labelColor: Color {
        switch field.kind {
        case .tool:       return Color.accentColor
        case .errorField: return .red
        case .metadata:   return Color.secondary.opacity(0.5)
        default:          return .secondary
        }
    }

    private var valueColor: Color {
        switch field.kind {
        case .errorField: return .red
        case .metadata:   return Color.secondary.opacity(0.45)
        default:          return .primary
        }
    }
}
