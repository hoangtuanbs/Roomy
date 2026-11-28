import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// One release in a Sparkle update feed (appcast).
public struct AppcastItem: Sendable, Equatable {
    /// `sparkle:version`, compared with the app's `CFBundleVersion`.
    public let version: String?
    /// `sparkle:shortVersionString`, the version people see.
    public let shortVersion: String?
    public let downloadURL: URL?
    public let releaseNotesURL: URL?
    public let minimumSystemVersion: String?

    public init(version: String?, shortVersion: String?, downloadURL: URL?, releaseNotesURL: URL? = nil,
                minimumSystemVersion: String? = nil) {
        self.version = version
        self.shortVersion = shortVersion
        self.downloadURL = downloadURL
        self.releaseNotesURL = releaseNotesURL
        self.minimumSystemVersion = minimumSystemVersion
    }

    /// The version to show: the short one when there is one.
    public var displayVersion: String { shortVersion ?? version ?? "?" }
}

/// Reads Sparkle appcasts: RSS with an `<item>` per release and the version on its `<enclosure>` or in
/// `sparkle:` elements. Beta channels and delta updates are skipped.
public enum Appcast {
    public static func parse(_ data: Data) -> [AppcastItem] {
        let reader = AppcastReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        parser.parse()
        return reader.items
    }

    /// The newest release that runs on `systemVersion`.
    public static func newest(_ items: [AppcastItem], systemVersion: String) -> AppcastItem? {
        items.filter { item in
            guard let minimum = item.minimumSystemVersion else { return true }
            return VersionCompare.compare(minimum, systemVersion) != .orderedDescending
        }
        .max { a, b in
            VersionCompare.compare(a.version ?? a.shortVersion ?? "", b.version ?? b.shortVersion ?? "") == .orderedAscending
        }
    }
}

private final class AppcastReader: NSObject, XMLParserDelegate {
    var items: [AppcastItem] = []
    private var inItem = false
    private var deltaDepth = 0
    private var skip = false
    private var text = ""
    private var version: String?
    private var shortVersion: String?
    private var download: URL?
    private var notes: URL?
    private var link: URL?
    private var minimum: String?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "item":
            inItem = true
            skip = false
            version = nil; shortVersion = nil; download = nil; notes = nil; link = nil; minimum = nil
        case "sparkle:deltas":
            deltaDepth += 1
        case "enclosure" where inItem && deltaDepth == 0:
            if let value = attributes["sparkle:version"] { version = value }
            if let value = attributes["sparkle:shortVersionString"] { shortVersion = value }
            if let url = attributes["url"].flatMap(URL.init(string:)) { download = url }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard inItem else { return }
        switch name {
        case "sparkle:deltas": deltaDepth = max(0, deltaDepth - 1)
        case "sparkle:version" where !value.isEmpty: version = value
        case "sparkle:shortVersionString" where !value.isEmpty: shortVersion = value
        case "sparkle:releaseNotesLink": notes = URL(string: value)
        case "sparkle:fullReleaseNotesLink": if notes == nil { notes = URL(string: value) }
        case "sparkle:minimumSystemVersion" where !value.isEmpty: minimum = value
        case "sparkle:channel" where !value.isEmpty: skip = true
        case "link": link = URL(string: value)
        case "item":
            inItem = false
            if !skip && (version != nil || shortVersion != nil) {
                items.append(AppcastItem(version: version, shortVersion: shortVersion, downloadURL: download ?? link,
                                         releaseNotesURL: notes ?? link, minimumSystemVersion: minimum))
            }
        default: break
        }
        text = ""
    }
}

/// Compares version strings the way Sparkle does: runs of digits as numbers, runs of letters as text, and a letter
/// part after a shorter version marks a pre-release ("2.0b1" comes before "2.0").
public enum VersionCompare {
    enum Part: Equatable {
        case number(UInt64)
        case text(String)
    }

    static func parts(_ version: String) -> [Part] {
        var out: [Part] = []
        var current = ""
        var isDigit: Bool?
        func flush() {
            guard !current.isEmpty else { return }
            if isDigit == true { out.append(.number(UInt64(current.prefix(18)) ?? 0)) } else { out.append(.text(current.lowercased())) }
            current = ""
        }
        for ch in version {
            if ch.isASCII && ch.isNumber {
                if isDigit == false { flush() }
                isDigit = true
                current.append(ch)
            } else if ch.isLetter {
                if isDigit == true { flush() }
                isDigit = false
                current.append(ch)
            } else {
                flush()
                isDigit = nil
            }
        }
        flush()
        return out
    }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            switch (i < x.count ? x[i] : nil, i < y.count ? y[i] : nil) {
            case let (.number(p)?, .number(q)?):
                if p != q { return p < q ? .orderedAscending : .orderedDescending }
            case let (.text(p)?, .text(q)?):
                if p != q { return p < q ? .orderedAscending : .orderedDescending }
            case (.number?, .text?): return .orderedDescending
            case (.text?, .number?): return .orderedAscending
            case (.text?, nil): return .orderedAscending   // "2.0b1" < "2.0"
            case (nil, .text?): return .orderedDescending
            case (.number(let p)?, nil): if p != 0 { return .orderedDescending }
            case (nil, .number(let q)?): if q != 0 { return .orderedAscending }
            case (nil, nil): break
            }
        }
        return .orderedSame
    }
}

/// Downloads an update feed. The app uses `URLSessionAppcastFetcher`; tests and the flow test use a fixed one, so
/// nothing goes to the network there.
public protocol AppcastFetching: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

public struct URLSessionAppcastFetcher: AppcastFetching {
    public init() {}

    public func fetch(_ url: URL) async throws -> Data {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw URLError(.unsupportedURL)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("RoomyDisk", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// Feeds given in advance, by URL.
public struct FixedAppcastFetcher: AppcastFetching {
    public let feeds: [String: Data]
    public init(_ feeds: [String: Data]) { self.feeds = feeds }

    public func fetch(_ url: URL) async throws -> Data {
        guard let data = feeds[url.absoluteString] else { throw URLError(.cannotFindHost) }
        return data
    }
}

/// What RoomyDisk knows about an app's updates.
public enum UpdateStatus: Sendable, Equatable {
    case available(AppcastItem)
    case upToDate
    /// From the Mac App Store, which updates it.
    case appStore
    case failed(String)
}

/// Checks installed apps for updates: Sparkle apps through their feed (`SUFeedURL`), App Store apps are pointed to
/// the App Store. It only reads; nothing is downloaded or installed.
public struct UpdateChecker: Sendable {
    public let fetcher: any AppcastFetching
    public let systemVersion: String

    public init(fetcher: any AppcastFetching, systemVersion: String = UpdateChecker.currentSystemVersion) {
        self.fetcher = fetcher
        self.systemVersion = systemVersion
    }

    public static var currentSystemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Apps that can be checked: those with an update feed, and those from the App Store.
    public static func checkable(_ apps: [InstalledApp]) -> [InstalledApp] {
        apps.filter { !$0.isApple && ($0.isFromAppStore || $0.feedURL != nil) }
    }

    public func check(_ app: InstalledApp) async -> UpdateStatus {
        if app.isFromAppStore { return .appStore }
        guard let feed = app.feedURL, let url = URL(string: feed) else { return .failed(String(localized: "No update feed")) }
        do {
            let data = try await fetcher.fetch(url)
            let items = Appcast.parse(data)
            guard let newest = Appcast.newest(items, systemVersion: systemVersion) else {
                return .failed(String(localized: "The update feed lists no versions."))
            }
            return Self.status(of: app, newest: newest)
        } catch {
            return .failed(String(localized: "Could not reach the update feed."))
        }
    }

    /// Compares like Sparkle: the feed's `sparkle:version` with the app's `CFBundleVersion`, or the short versions
    /// when one of those is missing.
    public static func status(of app: InstalledApp, newest: AppcastItem) -> UpdateStatus {
        let result: ComparisonResult
        if let theirs = newest.version, let ours = app.buildVersion {
            result = VersionCompare.compare(ours, theirs)
        } else if let theirs = newest.shortVersion ?? newest.version, let ours = app.version {
            result = VersionCompare.compare(ours, theirs)
        } else {
            return .failed(String(localized: "The app's version is unknown."))
        }
        return result == .orderedAscending ? .available(newest) : .upToDate
    }

    /// Checks several apps, a few at a time, and reports each as it comes in.
    public func checkAll(_ apps: [InstalledApp], each: @escaping @Sendable (String, UpdateStatus) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for app in apps {
                if running >= 6 {
                    _ = await group.next()
                    running -= 1
                }
                group.addTask {
                    let status = await self.check(app)
                    await each(app.path, status)
                }
                running += 1
            }
            await group.waitForAll()
        }
    }
}
