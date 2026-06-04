// RoutePicker.swift — DoomCoder Mac
// Inline radio picker that lets the user choose between the two routes
// when creating a new connection: implicit iCloud (same Apple ID) or
// explicit iCloud Share (different Apple ID).

import SwiftUI
import DoomCoderCore

struct RoutePicker: View {
    @Binding var selection: RouteKind

    enum RouteKind: String, CaseIterable, Identifiable {
        case iCloud = "iCloud (same Apple ID)"
        case ckShare = "iCloud Share (different Apple ID)"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .iCloud:   return "icloud"
            case .ckShare:  return "person.2.crop.square.stack"
            }
        }
    }

    var body: some View {
        Picker("Route", selection: $selection) {
            ForEach(RouteKind.allCases) { kind in
                Label(kind.rawValue, systemImage: kind.icon).tag(kind)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}
