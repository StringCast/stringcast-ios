import XCTest
@testable import StringCast

final class CheckInHeadersTests: XCTestCase {
    let app = CheckInHeaders.AppInfo(appId: "com.example.app", appVersion: "2.3.1")

    func manifest(version: Int) -> Manifest {
        Manifest(projectId: "p", version: version, baseLanguage: "en", languages: [
            .init(code: "en", url: "http://localhost:8787/v1/sdk/p/bundles/\(version)/en.json"),
            .init(code: "es", url: "http://localhost:8787/v1/sdk/p/bundles/\(version)/es.json"),
            .init(code: "fr", url: "https://cdn.example.com/p/v\(version)/fr.json"),
        ])
    }

    func makeEngine(transport: MockTransport, store: BundleStore = InMemoryBundleStore(),
                    override: String? = nil, draftMode: Bool = false) -> StringCastEngine {
        let config = StringCastConfig(projectId: "p", sdkKey: "pk_test", baseURL: URL(string: "http://localhost:8787")!,
                                      languageOverride: override, draftMode: draftMode, missingKeyDebounce: 0.05)
        return StringCastEngine(config: config, store: store, transport: transport, appStrings: { _ in nil },
                                preferredLanguages: { ["es-MX"] }, appInfo: app)
    }

    func serve(_ transport: MockTransport, version: Int) {
        let m = manifest(version: version)
        transport.handlers["/v1/sdk/p/manifest"] = { _ in (200, ["ETag": "\"v\(version)\""], try! JSONEncoder().encode(m)) }
        for lang in ["en", "es"] {
            let b = TranslationBundle(projectId: "p", version: version, language: lang, strings: ["title": .string(lang)])
            transport.handlers["/v1/sdk/p/bundles/\(version)/\(lang).json"] = { _ in (200, [:], try! JSONEncoder().encode(b)) }
        }
        let fr = TranslationBundle(projectId: "p", version: version, language: "fr", strings: ["title": .string("fr")])
        transport.handlers["/p/v\(version)/fr.json"] = { _ in (200, [:], try! JSONEncoder().encode(fr)) }
    }

    private func checkInHeaders(_ r: URLRequest) -> [String: String] {
        (r.allHTTPHeaderFields ?? [:]).filter { $0.key.lowercased().hasPrefix("x-stringcast-") }
    }

    // MARK: Pure builder

    func testBuildOmitsEmptyAndSanitises() {
        XCTAssertEqual(CheckInHeaders.build(app: app, sdkVersion: "0.1.0", language: "es"), [
            "X-StringCast-Platform": "ios",
            "X-StringCast-App-Id": "com.example.app",
            "X-StringCast-App-Version": "2.3.1",
            "X-StringCast-SDK-Version": "0.1.0",
            "X-StringCast-Language": "es",
        ])
        let sparse = CheckInHeaders.build(app: .init(appId: nil, appVersion: "βé"), language: "")
        XCTAssertEqual(Set(sparse.keys), ["X-StringCast-Platform", "X-StringCast-SDK-Version"])
        XCTAssertEqual(CheckInHeaders.asciiSafe(" 1.0 (β)\r\n"), "1.0 ()")
        XCTAssertEqual(StringCast.sdkVersion, "0.1.2")
        XCTAssertEqual(StringCastConfig.defaultBaseURL.absoluteString, "https://console.stringcast.app")
    }

    // MARK: Wire level

    func testManifestCarriesHeadersAndBundlesDoNot() async {
        let transport = MockTransport()
        serve(transport, version: 4)
        let engine = makeEngine(transport: transport)

        await engine.refresh(force: true) // no cache, no override → language not resolvable yet
        let first = transport.requests.first { $0.url?.path == "/v1/sdk/p/manifest" }!
        XCTAssertEqual(checkInHeaders(first), [
            "X-StringCast-Platform": "ios",
            "X-StringCast-App-Id": "com.example.app",
            "X-StringCast-App-Version": "2.3.1",
            "X-StringCast-SDK-Version": StringCast.sdkVersion,
        ])

        await engine.refresh(force: true) // manifest known now → resolved language es
        let second = transport.requests.filter { $0.url?.path == "/v1/sdk/p/manifest" }[1]
        XCTAssertEqual(second.value(forHTTPHeaderField: "X-StringCast-Language"), "es")

        engine.setLanguage("fr") // CDN bundle on another host
        await engine.ensureBundles()
        await engine.refresh(force: true)
        let third = transport.requests.filter { $0.url?.path == "/v1/sdk/p/manifest" }[2]
        XCTAssertEqual(third.value(forHTTPHeaderField: "X-StringCast-Language"), "fr")

        let bundles = transport.requests.filter { $0.url?.path.hasSuffix(".json") == true }
        XCTAssertTrue(bundles.contains { $0.url?.host == "cdn.example.com" })
        XCTAssertGreaterThanOrEqual(bundles.count, 3)
        for r in bundles {
            XCTAssertEqual(checkInHeaders(r), [:], "bundle \(r.url!) must not carry check-in headers")
            if r.url?.host == "cdn.example.com" { XCTAssertNil(r.value(forHTTPHeaderField: "X-Api-Key")) }
        }
    }

    func testOverrideIsSentBeforeAnyManifest() async {
        let transport = MockTransport()
        let engine = makeEngine(transport: transport, override: "fr")
        await engine.refresh(force: true) // 404, swallowed
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "X-StringCast-Language"), "fr")
    }

    func testMissingReportCarriesHeaders() async {
        let transport = MockTransport()
        let store = InMemoryBundleStore(
            manifest: CachedManifest(manifest: manifest(version: 3), etag: "\"v3\"", lastCheck: Date()),
            bundles: [TranslationBundle(projectId: "p", version: 3, language: "en", strings: [:])]
        )
        let exp = expectation(description: "posted")
        var seen: URLRequest?
        transport.handlers["/v1/sdk/p/missing"] = { req in
            seen = req
            exp.fulfill()
            return (200, [:], Data(#"{"created":1,"ignored":0}"#.utf8))
        }
        let engine = makeEngine(transport: transport, store: store, draftMode: true)
        _ = engine.string("new_key", defaultValue: "New", args: [])
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(checkInHeaders(seen!), [
            "X-StringCast-Platform": "ios",
            "X-StringCast-App-Id": "com.example.app",
            "X-StringCast-App-Version": "2.3.1",
            "X-StringCast-SDK-Version": StringCast.sdkVersion,
            "X-StringCast-Language": "es",
        ])
    }
}
