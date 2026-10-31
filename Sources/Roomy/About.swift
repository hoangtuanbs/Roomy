import AppKit

/// Shows the standard About panel with the author, companies, licence and project link.
enum About {
    static let author = "hoangtuanbs"
    static let companies = ["DanaExperts Co. Ltd.", "DanaExperts Finland Oy"]
    static let projectURL = URL(string: "https://github.com/hoangtuanbs/Roomy")!
    static let supportEmail = "hoangtuanbs@proton.me"

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    static var supportMailURL: URL? {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Roomy \(version) support"),
            URLQueryItem(name: "body", value: "Describe the problem here:\n\n\n---\nRoomy \(version)\nmacOS \(os)"),
        ]
        return components.url
    }

    /// The app to write the email in. The default mailto handler is often a web browser (Chrome, for example),
    /// which silently ignores the link unless a webmail site registered for it, so prefer a real mail app then.
    static func mailApp(for url: URL) -> URL? {
        let workspace = NSWorkspace.shared
        let browsers = Set(workspace.urlsForApplications(toOpen: URL(string: "https://example.com")!))
        if let preferred = workspace.urlForApplication(toOpen: url), !browsers.contains(preferred) {
            return preferred
        }
        let mailApps = workspace.urlsForApplications(toOpen: url).filter { !browsers.contains($0) }
        return mailApps.first { $0.lastPathComponent == "Mail.app" } ?? mailApps.first
    }

    /// Opens a new email to support, with the app and macOS versions filled in.
    /// If no mail app can take it, shows the address instead, so the click never does nothing.
    static func emailSupport() {
        guard let url = supportMailURL, let app = mailApp(for: url) else {
            showSupportAddress()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
            if error != nil {
                DispatchQueue.main.async { showSupportAddress() }
            }
        }
    }

    static func showSupportAddress() {
        let alert = NSAlert()
        alert.messageText = "Email us at \(supportEmail)"
        alert.informativeText = "Roomy could not open an email app. Copy the address and write to us from your email."
        alert.addButton(withTitle: "Copy Address")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(supportEmail, forType: .string)
        }
    }

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
        text.append(NSAttributedString(string: "github.com/hoangtuanbs/Roomy\n\n", attributes: link))
        // Plain text: a mailto link here would go to the default handler, which may be a browser that ignores it.
        // Help > Email Us… picks a real mail app.
        text.append(NSAttributedString(string: "Help: \(supportEmail)", attributes: body))
        return text
    }
}
