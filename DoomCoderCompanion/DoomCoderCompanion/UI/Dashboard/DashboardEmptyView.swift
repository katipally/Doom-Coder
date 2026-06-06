// DashboardEmptyView.swift — DoomCoder Companion
// Empty state for the Dashboard when no Mac is paired. Shows a short,
// friendly guide telling the user exactly what to do ON THE MAC to pair —
// because in v6 the Mac is the initiator of every pairing. Same-Apple-ID
// pairing happens entirely from the Mac (the iPhone just accepts a prompt);
// a different Apple ID uses the QR/code/link via "Add a Mac".

import SwiftUI

struct DashboardEmptyView: View {
    @State private var showingAddMac = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Let's connect your Mac")
                    .font(.title3.weight(.semibold))
                Text("DoomCoder must be running on your Mac. The Mac starts the pairing — here's how:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                GuideStep(number: 1, icon: "menubar.arrow.up.rectangle",
                          text: "On your Mac, open **DoomCoder** and click its menu-bar icon.")
                GuideStep(number: 2, icon: "rectangle.stack.badge.person.crop",
                          text: "Go to **Connections ▸ Add Device**.")
                GuideStep(number: 3, icon: "person.2.fill",
                          text: "**Same Apple ID?** Pick the **Same iCloud** tab, choose this iPhone, then accept the prompt here.")
                GuideStep(number: 4, icon: "qrcode.viewfinder",
                          text: "**Different Apple ID?** Use **Different iCloud** and scan the QR (or type the code) with **Add a Mac** below.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button {
                showingAddMac = true
            } label: {
                Label("Add a Mac (different Apple ID)", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .center)
        .listRowBackground(Color.clear)
        .sheet(isPresented: $showingAddMac) {
            AddMacView()
        }
    }
}

private struct GuideStep: View {
    let number: Int
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.15))
                    .frame(width: 28, height: 28)
                Text("\(number)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(.init(text))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }
}
