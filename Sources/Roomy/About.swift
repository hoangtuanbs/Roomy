import AppKit

/// Shows the standard About panel with the author, companies, licence and project link.
enum About {
    static let author = "hoangtuanbs"
    static let companies = ["DanaExperts Co. Ltd.", "DanaExperts Finland Oy"]
    static let projectURL = URL(string: "https://github.com/hoangtuanbs/Roomy")!

    static func show() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Name, icon, version and the copyright line (NSHumanReadableCopyright) come from the bundle.
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits()])
    }

    private static func credits() -> NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 2
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: center,
        ]
        var strong = body
        strong[.font] = NSFont.systemFont(ofSize: 11, weight: .semibold)

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Made by \(author)\n", attributes: strong))
        text.append(NSAttributedString(string: companies.joined(separator: "\n") + "\n\n", attributes: body))
        text.append(NSAttributedString(string: "Released under the MIT License\n", attributes: body))
        var link = body
        link[.link] = projectURL
        text.append(NSAttributedString(string: "github.com/hoangtuanbs/Roomy", attributes: link))
        return text
    }
}
