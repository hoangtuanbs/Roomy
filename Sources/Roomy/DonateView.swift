import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

enum Donation {
    static let ethereumAddress = "0xF8352b493e7750C03bde4bdA94A203B010933735"
    /// EIP-681 payment link, which wallet apps open as a send screen to this address.
    static var ethereumURI: String { "ethereum:\(ethereumAddress)" }

    /// A crisp QR code for `text`, `size` points wide.
    static func qrCode(for text: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = (size * 2 / output.extent.width).rounded(.down)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width / 2, height: scaled.extent.height / 2))
    }
}

struct DonateView: View {
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "heart.fill")
                .font(.system(size: 30))
                .foregroundStyle(.pink)
            Text("Support Roomy").font(.title2.weight(.semibold))
            Text("Roomy is free and open source. If it helped you get space back, you can say thanks with a donation in Ethereum.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let qr = Donation.qrCode(for: Donation.ethereumURI, size: 220) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                    .accessibilityLabel("QR code for the Ethereum address")
            }

            Text(Donation.ethereumAddress)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.center)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Donation.ethereumAddress, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy Address", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 130)
            }

            Text("Ethereum (ETH) address. Please double-check the address in your wallet before sending.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(26)
        .frame(width: 420)
    }
}
