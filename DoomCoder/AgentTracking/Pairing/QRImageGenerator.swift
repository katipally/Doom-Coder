// QRImageGenerator.swift — DoomCoder Mac
// Wraps Core Image's QRCodeGenerator filter and returns a high-contrast
// NSImage suitable for display in a SwiftUI view. The QR encodes a doomcoder://
// URL plus a short pairing code so iOS can accept via either path.

import Foundation
import AppKit
import CoreImage

public enum QRImageGenerator {

    public static func image(for url: URL, size: CGFloat = 256) -> NSImage? {
        guard let data = url.absoluteString.data(using: .utf8) else { return nil }
        return image(for: data, size: size)
    }

    public static func image(for data: Data, size: CGFloat = 256) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }
        let scale = size / max(ciImage.extent.width, 1)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }
}
