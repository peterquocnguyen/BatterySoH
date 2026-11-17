import Foundation

// F12 — Check for updates. One HTTPS GET to GitHub's "latest release" endpoint; nothing about
// the user or the Mac is sent (the User-Agent names only the app and its version). Parsing and
// the decision are pure so they are tested with canned responses; only `check` touches the
// network, through an injectable transport.

/// A release version: `MAJOR.MINOR.PATCH`, an optional leading `v`, missing parts read as 0,
/// and an optional pre-release suffix (`1.2.0-beta.2`), which sorts before the release.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init(major: Int, minor: Int = 0, patch: Int = 0, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// nil for anything that isn't a version ("latest", "", "1.x").
    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        // Build metadata ("+abc") never affects ordering.
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        var pre: String?
        if let dash = s.firstIndex(of: "-") {
            let suffix = String(s[s.index(after: dash)...])
            guard !suffix.isEmpty else { return nil }
            pre = suffix
            s = String(s[..<dash])
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: pre)
    }

    /// "0.3.0", "1.2.0-beta.2".
    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil), (nil, _): return false
        case (_, nil): return true
        case (let x?, let y?): return x.compare(y, options: .numeric) == .orderedAscending
        }
    }
}

/// A published release, as much of it as the app shows.
public struct AppRelease: Equatable, Sendable {
    public var version: AppVersion
    /// "v0.3.0"
    public var tag: String
    /// "BatterySoH 0.3.0"
    public var name: String?
    /// Release page on GitHub (notes + downloads).
    public var pageURL: URL
    /// The first `.dmg` asset, when there is one.
    public var downloadURL: URL?
    public var notes: String?
    public var publishedAt: Date?

    public init(
        version: AppVersion, tag: String, name: String? = nil, pageURL: URL, downloadURL: URL? = nil,
        notes: String? = nil, publishedAt: Date? = nil
    ) {
        self.version = version
        self.tag = tag
        self.name = name
        self.pageURL = pageURL
        self.downloadURL = downloadURL
        self.notes = notes
        self.publishedAt = publishedAt
    }
}

public enum UpdateCheckOutcome: Equatable, Sendable {
    /// Running the newest release (or a newer one).
    case upToDate(latest: AppVersion?)
    case available(AppRelease)
    /// A short sentence for the UI ("GitHub couldn't be reached.").
    case failed(String)
}

public enum UpdateChecker {
    public static let repository = "peterquocnguyen/BatterySoH"
    // Literal URLs: these cannot fail to parse.
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    /// Automatic checks run at most this often.
    public static let automaticInterval: TimeInterval = 24 * 60 * 60

    /// Network transport: returns the body and the response. Tests pass a canned one.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Asks GitHub for the latest release and compares it with `current`. Never throws: every
    /// failure becomes `.failed` with a sentence for the UI.
    public static func check(currentVersion current: String, transport: Transport? = nil) async -> UpdateCheckOutcome {
        let request = request(currentVersion: current)
        do {
            let (data, response) = try await (transport ?? defaultTransport)(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return outcome(currentVersion: current, statusCode: status, body: data)
        } catch is CancellationError {
            return .failed("The check was cancelled.")
        } catch let error as URLError {
            return .failed(message(for: error))
        } catch {
            return .failed("GitHub couldn't be reached.")
        }
    }

    /// The request `check` sends: no cookies, no cache, a 15 s timeout.
    public static func request(currentVersion: String) -> URLRequest {
        var request = URLRequest(
            url: latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub rejects requests without a User-Agent. App name and version only.
        request.setValue("BatterySoH/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Pure: what an HTTP status and body mean for `current`.
    public static func outcome(currentVersion current: String, statusCode: Int, body: Data) -> UpdateCheckOutcome {
        switch statusCode {
        case 200:
            guard let release = parseRelease(body) else {
                return .failed("GitHub sent a release this version can't read.")
            }
            return decide(currentVersion: current, latest: release)
        case 404:
            // Releases exist, so a 404 means the repository moved, went private or was deleted:
            // say so rather than report "up to date" forever.
            return .failed("No published release was found on GitHub.")
        case 403, 429:
            return .failed("GitHub is limiting requests right now. Try again in an hour.")
        case 500...599:
            return .failed("GitHub is having trouble (HTTP \(statusCode)). Try again later.")
        default:
            return .failed("GitHub answered with HTTP \(statusCode).")
        }
    }

    /// Pure: newer → `.available`; same, older or unreadable current version → up to date.
    public static func decide(currentVersion current: String, latest: AppRelease) -> UpdateCheckOutcome {
        guard let mine = AppVersion(current) else {
            // An unbundled dev build: never nag.
            return .upToDate(latest: latest.version)
        }
        return latest.version > mine ? .available(latest) : .upToDate(latest: latest.version)
    }

    /// Pure: GitHub's release JSON → `AppRelease`. nil for drafts, pre-releases, a tag that isn't
    /// a version, or JSON without the fields we need.
    public static func parseRelease(_ data: Data) -> AppRelease? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = object["tag_name"] as? String,
            let version = AppVersion(tag), version.prerelease == nil,
            let page = (object["html_url"] as? String).flatMap(URL.init(string:)),
            Self.isGitHub(page)
        else { return nil }
        if object["draft"] as? Bool == true || object["prerelease"] as? Bool == true { return nil }

        let assets = object["assets"] as? [[String: Any]] ?? []
        let dmg = assets.lazy
            .compactMap { asset -> URL? in
                guard let name = asset["name"] as? String, name.lowercased().hasSuffix(".dmg"),
                    let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
                    Self.isGitHub(url)
                else { return nil }
                return url
            }
            .first
        let published = (object["published_at"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        let notes = (object["body"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AppRelease(
            version: version, tag: tag, name: name, pageURL: page, downloadURL: dmg, notes: notes,
            publishedAt: published)
    }

    /// Only GitHub pages are ever opened from a release response.
    static func isGitHub(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com")
    }

    /// Pure: whether an automatic check is due.
    public static func isDue(lastCheck: Date?, now: Date = Date(), interval: TimeInterval = automaticInterval) -> Bool {
        guard let lastCheck else { return true }
        // A clock set back (lastCheck in the future) must not block checks forever.
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now
    }

    static func message(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "This Mac is offline."
        case .timedOut:
            return "GitHub didn't answer in time."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "GitHub couldn't be reached."
        case .cancelled:
            return "The check was cancelled."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "The connection to GitHub isn't secure."
        default:
            return "GitHub couldn't be reached."
        }
    }

    /// Ephemeral session: no cookies, no cache, no credentials on disk.
    private static let defaultTransport: Transport = { request in
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }
}
