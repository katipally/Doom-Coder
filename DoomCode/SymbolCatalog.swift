import SwiftUI

// MARK: - SymbolCatalog
//
// Single source of truth for SF Symbol names used across the macOS app.
// Helps catch deprecations in one place and keeps spelling consistent
// (a typo'd `powerSleep` instead of `powersleep` is easy to miss at a
// call site). iOS has its own copy of the same catalog in
// `DoomCoderCompanion/UI/SymbolCatalog.swift`.
//
// To add a new symbol:
//   1. Add it to the appropriate namespace below
//   2. Replace all string-literal call sites (`Image(systemName: "foo")`)
//      with the constant (`SymbolCatalog.status.foo`).
//
// This file deliberately exposes namespaces (Status, Action, etc.) rather
// than one flat bag of strings. Namespaces keep the call sites readable.

public enum SymbolCatalog {

    public enum Status {
        public static let active = "checkmark.circle.fill"
        public static let warning = "exclamationmark.triangle.fill"
        public static let error = "xmark.octagon.fill"
        public static let failure = "xmark.circle.fill"
        public static let info = "info.circle"
        public static let question = "questionmark.circle"
        public static let success = "checkmark.seal.fill"
        public static let bellSlash = "bell.slash.fill"
        public static let bellOn = "bell.badge.fill"
        public static let offline = "wifi.exclamationmark"
        public static let timer = "timer"
        public static let userActive = "hand.tap.fill"
        public static let moon = "moon.fill"
        public static let moonSnooze = "moon.zzz.fill"
        public static let powersleep = "powersleep"
        public static let display = "display"
    }

    public enum Action {
        public static let install = "arrow.down.circle.fill"
        public static let reinstall = "arrow.clockwise"
        public static let uninstall = "trash"
        public static let repair = "wrench.and.screwdriver"
        public static let reveal = "folder"
        public static let openInIDE = "arrow.up.forward.app"
        public static let refresh = "arrow.clockwise"
        public static let add = "plus.circle.fill"
        public static let remove = "minus.circle"
        public static let close = "xmark.circle.fill"
        public static let copy = "doc.on.doc"
        public static let edit = "pencil"
        public static let send = "arrow.up"
        public static let stop = "stop.fill"
        public static let help = "info.circle"
        public static let chevronRight = "chevron.right"
        public static let chevronDown = "chevron.down"
        public static let chevronUpDown = "chevron.up.chevron.down"
        public static let chevronUp = "chevron.up"
        public static let more = "ellipsis.circle"
        public static let qr = "qrcode"
        public static let qrViewfinder = "qrcode.viewfinder"
        public static let boltOn = "bolt.fill"
        public static let boltOff = "bolt.slash.fill"
        public static let pin = "pin"
        public static let pinSlash = "pin.slash"
        public static let pinFill = "pin.fill"
        public static let addPerson = "person.crop.rectangle.stack.fill"
        public static let personMultiple = "person.2"
        public static let personVerified = "person.crop.circle.badge.checkmark"
        public static let icloud = "icloud"
        public static let icloudSlash = "icloud.slash"
        public static let icloudOn = "checkmark.icloud.fill"
        public static let key = "key.fill"
        public static let keySlash = "key.slash"
        public static let clipboard = "doc.on.clipboard"
        public static let arrowRight = "arrow.right.circle.fill"
        public static let appDownload = "arrow.down.app.fill"
        public static let playCircle = "play.circle"
        public static let playCircleFill = "play.circle.fill"
        public static let handWave = "hand.wave"
        public static let handRaised = "hand.raised"
        public static let settings = "gearshape"
        public static let settings2 = "gearshape.2.fill"
        public static let wrench = "wrench.adjustable"
        public static let doc = "doc.on.doc"
        public static let shield = "lock.shield"
        public static let shieldCheck = "checkmark.shield"
        public static let heart = "heart.text.square"
        public static let search = "magnifyingglass"
        public static let sync = "arrow.triangle.2.circlepath"
        public static let sparkle = "sparkles"
        public static let refreshShield = "checkmark.shield"
        public static let history = "clock.arrow.circlepath"
        public static let tray = "tray"
        public static let antenna = "antenna.radiowaves.left.and.right"
        public static let stethoscope = "stethoscope"
        public static let stethoscopeEKG = "waveform.path.ecg"
        public static let listClipboard = "list.bullet.clipboard"
        public static let sidebar = "sidebar.left"
        public static let sidebarRight = "sidebar.right"
        public static let listRect = "list.bullet.rectangle"
        public static let bulletDoc = "doc.text"
        public static let phoneSlash = "iphone.slash"
        public static let phoneGen = "iphone.gen3"
        public static let phoneMac = "macbook.and.iphone"
        public static let desktop = "desktopcomputer"
        public static let macbookSlash = "macbook.slash"
        public static let bellBadge = "bell.badge"
        public static let bellFill = "bell.fill"
        public static let wrenchScrew = "wrench.and.screwdriver"
        public static let gear2 = "gearshape.2.fill"
        public static let boltSlash = "bolt.slash.fill"
        public static let dot = "circle.fill"
        public static let dotEmpty = "circle"
        public static let dotSeal = "checkmark.seal.fill"
        public static let dotX = "xmark.circle"
        public static let appBadge = "app.badge.checkmark"
        public static let sealCheck = "checkmark.seal.fill"
        public static let pencil = "pencil"
        public static let docText = "doc.text"
        public static let newDoc = "square.and.pencil"
        public static let books = "books.vertical"
        public static let inbox = "tray"
        public static let trash = "trash"
        public static let hourglass = "hourglass"
        public static let cup = "cup.and.saucer.fill"
        public static let sun = "sun.max.fill"
    }

    public enum Agent {
        public static let claude = "chevron.left.forwardslash.chevron.right"
    }
}
