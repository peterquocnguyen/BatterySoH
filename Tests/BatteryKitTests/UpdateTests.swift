import Foundation
import Testing

@testable import BatteryKit

@Suite("AppVersion")
struct AppVersionTests {
    @Test(arguments: [
        ("0.2.0", "0.2.0"), ("v0.3.1", "0.3.1"), ("V1", "1.0.0"), ("1.2", "1.2.0"),
        (" 2.0.0 \n", "2.0.0"), ("1.2.0-beta.2", "1.2.0-beta.2"), ("1.0.0+build.7", "1.0.0"),
    ])
    func parses(_ text: String, _ expected: String) {
        #expect(AppVersion(text)?.description == expected)
    }

    @Test(arguments: ["", "v", "latest", "1.x", "1..2", "1.2.3.4", "-1.0", "1.0-", "١.٢.٣"])
    func rejects(_ text: String) {
        #expect(AppVersion(text) == nil)
    }

    @Test func orders() throws {
        let ordered = ["0.1.9", "0.2.0", "0.2.1", "0.10.0", "1.0.0-alpha", "1.0.0-beta.2", "1.0.0-beta.10", "1.0.0"]
        let versions = try ordered.map { try #require(AppVersion($0)) }
        #expect(versions == versions.sorted())
        for (a, b) in zip(versions, versions.dropFirst()) {
            #expect(a < b, "\(a) < \(b)")
            #expect(!(b < a))
        }
        #expect(AppVersion("v1.0") == AppVersion("1.0.0"))
        #expect(!(AppVersion(major: 1) < AppVersion(major: 1)))
    }
}

@Suite("Update check")
struct UpdateCheckTests {
    static func releaseJSON(
        tag: String = "v0.3.0", draft: Bool = false, prerelease: Bool = false,
        page: String = "https://github.com/peterquocnguyen/BatterySoH/releases/tag/v0.3.0",
        assets: [[String: Any]] = [
            ["name": "BatterySoH-0.3.0.zip", "browser_download_url": "https://example.test/a.zip"],
            ["name": "Elsewhere.dmg", "browser_download_url": "https://example.test/x.dmg"],
            [
                "name": "BatterySoH-0.3.0.dmg",
                "browser_download_url":
                    "https://github.com/peterquocnguyen/BatterySoH/releases/download/v0.3.0/BatterySoH-0.3.0.dmg",
            ],
        ]
    ) -> Data {
        let object: [String: Any] = [
            "tag_name": tag, "name": "BatterySoH 0.3.0", "html_url": page, "draft": draft,
            "prerelease": prerelease, "published_at": "2026-11-20T09:30:00Z", "body": "## New\n- Updates",
            "assets": assets,
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    @Test func parsesRelease() throws {
        let release = try #require(UpdateChecker.parseRelease(Self.releaseJSON()))
        #expect(release.version == AppVersion(major: 0, minor: 3))
        #expect(release.tag == "v0.3.0")
        #expect(release.name == "BatterySoH 0.3.0")
        #expect(release.pageURL.absoluteString.hasSuffix("/releases/tag/v0.3.0"))
        #expect(release.downloadURL?.lastPathComponent == "BatterySoH-0.3.0.dmg")
        #expect(release.notes?.hasPrefix("## New") == true)
        #expect(release.publishedAt == Date(timeIntervalSinceReferenceDate: 816_859_800))
    }

    @Test func ignoresDraftsPrereleasesAndJunk() {
        #expect(UpdateChecker.parseRelease(Self.releaseJSON(draft: true)) == nil)
        #expect(UpdateChecker.parseRelease(Self.releaseJSON(prerelease: true)) == nil)
        #expect(UpdateChecker.parseRelease(Self.releaseJSON(tag: "v0.3.0-rc.1")) == nil)
        #expect(UpdateChecker.parseRelease(Self.releaseJSON(tag: "nightly")) == nil)
        #expect(UpdateChecker.parseRelease(Self.releaseJSON(page: "http://github.com/x")) == nil)
        #expect(UpdateChecker.parseRelease(Self.releaseJSON(page: "https://evil.test/releases")) == nil)
        #expect(UpdateChecker.parseRelease(Self.releaseJSON(page: "https://github.com.evil.test/x")) == nil)
        #expect(UpdateChecker.parseRelease(Data("not json".utf8)) == nil)
        #expect(UpdateChecker.parseRelease(Data("[1, 2]".utf8)) == nil)
    }

    @Test func releaseWithoutDMGStillParses() throws {
        let release = try #require(UpdateChecker.parseRelease(Self.releaseJSON(assets: [])))
        #expect(release.downloadURL == nil)
    }

    @Test func decides() throws {
        let release = try #require(UpdateChecker.parseRelease(Self.releaseJSON()))
        #expect(UpdateChecker.decide(currentVersion: "0.2.0", latest: release) == .available(release))
        #expect(UpdateChecker.decide(currentVersion: "0.3.0", latest: release) == .upToDate(latest: release.version))
        #expect(UpdateChecker.decide(currentVersion: "0.4.0", latest: release) == .upToDate(latest: release.version))
        // A pre-release of the same version is older than the release.
        #expect(UpdateChecker.decide(currentVersion: "0.3.0-beta.1", latest: release) == .available(release))
        // Unknown current version (dev build): never nag.
        #expect(UpdateChecker.decide(currentVersion: "dev", latest: release) == .upToDate(latest: release.version))
    }

    @Test func mapsHTTPStatus() {
        let ok = UpdateChecker.outcome(currentVersion: "0.2.0", statusCode: 200, body: Self.releaseJSON())
        guard case .available(let release) = ok else {
            Issue.record("expected .available, got \(ok)")
            return
        }
        #expect(release.tag == "v0.3.0")
        for status in [404, 403, 429, 502, 418] {
            guard
                case .failed(let message) = UpdateChecker.outcome(
                    currentVersion: "0.2.0", statusCode: status, body: Data())
            else {
                Issue.record("HTTP \(status) should fail")
                continue
            }
            #expect(!message.isEmpty)
        }
        guard case .failed = UpdateChecker.outcome(currentVersion: "0.2.0", statusCode: 200, body: Data("{}".utf8))
        else {
            Issue.record("an unreadable 200 should fail")
            return
        }
    }

    @Test func requestSendsNothingPersonal() {
        let request = UpdateChecker.request(currentVersion: "0.3.0")
        #expect(request.url == UpdateChecker.latestReleaseAPI)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "BatterySoH/0.3.0")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.timeoutInterval == 15)
        #expect(request.url?.query == nil)
    }

    @Test func checkUsesTransport() async {
        let body = Self.releaseJSON()
        let outcome = await UpdateChecker.check(currentVersion: "0.2.0") { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
        guard case .available(let release) = outcome else {
            Issue.record("expected .available, got \(outcome)")
            return
        }
        #expect(release.version == AppVersion("0.3.0"))
    }

    @Test(arguments: [
        URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .cancelled,
        .serverCertificateUntrusted, .badServerResponse,
    ])
    func checkTurnsNetworkErrorsIntoMessages(_ code: URLError.Code) async {
        let outcome = await UpdateChecker.check(currentVersion: "0.2.0") { _ in throw URLError(code) }
        guard case .failed(let message) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(message == UpdateChecker.message(for: URLError(code)))
        #expect(message.hasSuffix("."))
    }

    @Test func checkSurvivesOtherErrors() async {
        struct Boom: Error {}
        let other = await UpdateChecker.check(currentVersion: "0.2.0") { _ in throw Boom() }
        #expect(other == .failed("GitHub couldn't be reached."))
        let cancelled = await UpdateChecker.check(currentVersion: "0.2.0") { _ in throw CancellationError() }
        #expect(cancelled == .failed("The check was cancelled."))
    }

    @Test func dueAfterInterval() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = UpdateChecker.automaticInterval
        #expect(UpdateChecker.isDue(lastCheck: nil, now: now))
        #expect(!UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-day + 60), now: now))
        #expect(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-day), now: now))
        // Clock moved back: the stored date is in the future; check rather than wait for it.
        #expect(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }
}
