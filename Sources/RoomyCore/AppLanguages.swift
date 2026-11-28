import Foundation
#if canImport(Security)
import Security
#endif

/// What an app's code signature says.
public enum CodeSignatureState: Sendable, Equatable {
    /// Not signed at all. Changing its files breaks nothing that macOS checks.
    case unsigned
    /// Signed, and the signature matches the files. Removing any file inside breaks it.
    case signed
    /// Signed by Apple.
    case apple
    /// Signed, but the signature does not match (or could not be checked).
    case invalid
}

/// Checks code signatures. The app uses `SystemSignatureChecker`; tests pass their own.
public protocol SignatureChecking: Sendable {
    func state(ofApp path: String) -> CodeSignatureState
}

/// `SecStaticCodeCheckValidity`, which reads the signature without running the app.
public struct SystemSignatureChecker: SignatureChecking {
    public init() {}

    public func state(ofApp path: String) -> CodeSignatureState {
        #if canImport(Security) && os(macOS)
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return .invalid }
        let status = SecStaticCodeCheckValidity(code, [], nil)
        if status == errSecCSUnsigned { return .unsigned }
        guard status == errSecSuccess else { return .invalid }
        var requirement: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess, let requirement,
           SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess {
            return .apple
        }
        return .signed
        #else
        return .invalid
        #endif
    }
}

/// The translations inside an app (`Contents/Resources/<language>.lproj`) for languages you do not use.
public struct LanguageFinding: Sendable, Equatable {
    public let appPath: String
    /// The `.lproj` folders of languages that are not in your preferred languages, largest first once measured.
    public var folders: [ReceiptFile]
    public let signature: CodeSignatureState

    public var bytes: Int64 { folders.reduce(0) { $0 + $1.bytes } }

    /// Only apps that are not signed can lose files without harm. Removing anything from a signed app breaks its
    /// signature: macOS may refuse to open it, and it can lose its permissions and keychain items. Those are only
    /// shown, as size information.
    public var canRemove: Bool { signature == .unsigned }
}

/// Finds the unused languages of an app.
public struct LanguageFinder: Sendable {
    /// Your languages, such as `["en-US", "vi"]`.
    public let preferredLanguages: [String]
    public let checker: any SignatureChecking
    public let policy: SafetyPolicy

    public init(preferredLanguages: [String] = Locale.preferredLanguages, checker: any SignatureChecking = SystemSignatureChecker(),
                policy: SafetyPolicy = SafetyPolicy()) {
        self.preferredLanguages = preferredLanguages
        self.checker = checker
        self.policy = policy
    }

    /// Old English names some apps use for their folders.
    static let legacyNames: [String: String] = [
        "english": "en", "french": "fr", "german": "de", "japanese": "ja", "spanish": "es", "italian": "it",
        "dutch": "nl", "portuguese": "pt", "swedish": "sv", "danish": "da", "finnish": "fi", "norwegian": "nb",
        "korean": "ko", "chinese": "zh", "russian": "ru", "polish": "pl",
    ]

    /// The language of a folder name or a preferred language: "zh_CN", "zh-Hans" and "zh-Hans-CN" are all "zh".
    static func language(_ name: String) -> String {
        let lower = name.lowercased()
        if let legacy = legacyNames[lower] { return legacy }
        let code = lower.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? lower
        // Norwegian is "no" in some apps and "nb" in macOS.
        return code == "no" ? "nb" : code
    }

    /// Nil for apps of macOS, apps in /System, apps without unused languages, and Apple's own.
    public func find(app: InstalledApp) -> LanguageFinding? {
        guard !app.isApple, !SafetyPolicy.isSameOrInside(app.path, "/System") else { return nil }
        let resources = app.path + "/Contents/Resources"
        let info = AppUninstaller.readPlist(app.path + "/Contents/Info.plist") ?? [:]
        var keep: Set<String> = ["base"]
        keep.formUnion(preferredLanguages.map(Self.language))
        if let development = info["CFBundleDevelopmentRegion"] as? String { keep.insert(Self.language(development)) }
        keep.insert("en") // Apps fall back to English when nothing else fits.

        var folders: [ReceiptFile] = []
        for entry in JunkFinder.entries(in: resources) where entry.kind == .directory && entry.name.hasSuffix(".lproj") {
            let name = String(entry.name.dropLast(".lproj".count))
            if keep.contains(Self.language(name)) { continue }
            let path = resources + "/" + entry.name
            guard !policy.verdict(for: path).isBlocked else { continue }
            folders.append(ReceiptFile(path: path))
        }
        guard !folders.isEmpty else { return nil }
        let signature = checker.state(ofApp: app.path)
        if signature == .apple { return nil }
        return LanguageFinding(appPath: app.path, folders: folders, signature: signature)
    }

    /// Measures the folders, largest first.
    public static func measure(_ finding: LanguageFinding) -> LanguageFinding {
        var measured = finding
        measured.folders = finding.folders
            .map { ReceiptFile(path: $0.path, bytes: DiskUsage.allocatedSize(atPath: $0.path)) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        return measured
    }
}

/// A signature checker that gives the same answer for every app, for tests and the app's flow test.
public struct FixedSignatureChecker: SignatureChecking {
    public let answer: CodeSignatureState
    public init(_ answer: CodeSignatureState) { self.answer = answer }
    public func state(ofApp path: String) -> CodeSignatureState { answer }
}
