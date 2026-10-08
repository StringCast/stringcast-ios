import XCTest
@testable import Polyglot

/// Scriptable transport: maps URL path → handler.
final class MockTransport: HTTPTransport {
    var handlers: [String: (URLRequest) -> (Int, [String: String], Data)] = [:]
    private(set) var requests: [URLRequest] = []
    private let lock = NSLock()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.locked { requests.append(request) }
        guard let url = request.url, let handler = handlers[url.path] else {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let (status, headers, body) = handler(request)
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    func count(path: String) -> Int { lock.locked { requests.filter { $0.url?.path == path }.count } }
}

final class EngineTests: XCTestCase {
    let base = TranslationBundle(projectId: "p", version: 3, language: "en", strings: [
        "title": .string("Hello"),
        "greeting": .string("Hi %s"),
        "only_base": .string("Base only"),
        "items": .plural(["one": "%d item", "other": "%d items"]),
        "planets": .array(["Mercury", "Venus"]),
        "broken": .string("Broken %d"),
    ])
    let es = TranslationBundle(projectId: "p", version: 3, language: "es", strings: [
        "title": .string("Hola"),
        "greeting": .string("Hola %1$s"),
        "items": .plural(["one": "%d artículo", "other": "%d artículos"]),
        "broken": .string("Roto %@"), // translator broke the placeholder type
    ])

    func manifest(version: Int = 3) -> Manifest {
        Manifest(projectId: "p", version: version, baseLanguage: "en", languages: [
            .init(code: "en", url: "http://localhost:8787/v1/sdk/p/bundles/\(version)/en.json"),
            .init(code: "es", url: "http://localhost:8787/v1/sdk/p/bundles/\(version)/es.json"),
        ])
    }

    func makeEngine(
        preferred: [String] = ["es-ES"],
        compiled: [String: String] = [:],
        store: BundleStore? = nil,
        transport: HTTPTransport = MockTransport(),
        draftMode: Bool = false,
        override: String? = nil
    ) -> PolyglotEngine {
        let store = store ?? InMemoryBundleStore(
            manifest: CachedManifest(manifest: manifest(), etag: "\"v3\"", lastCheck: Date()),
            bundles: [base, es]
        )
        let config = PolyglotConfig(projectId: "p", sdkKey: "pk_test", baseURL: URL(string: "http://localhost:8787")!,
                                    languageOverride: override, draftMode: draftMode, missingKeyDebounce: 0.05)
        return PolyglotEngine(config: config, store: store, transport: transport,
                              appStrings: { compiled[$0] }, preferredLanguages: { preferred })
    }

    // MARK: Lookup fallback (§6.5)

    func testLookupFallbackOrder() {
        let engine = makeEngine(compiled: ["compiled_only": "From app", "title": "App title"])
        XCTAssertEqual(engine.currentLanguage, "es")
        XCTAssertEqual(engine.string("title", defaultValue: nil, args: []), "Hola")               // resolved
        XCTAssertEqual(engine.string("only_base", defaultValue: nil, args: []), "Base only")      // base
        XCTAssertEqual(engine.string("compiled_only", defaultValue: "dflt", args: []), "From app") // compiled
        XCTAssertEqual(engine.string("nowhere", defaultValue: "Default %s", args: ["x"]), "Default x") // default
        XCTAssertEqual(engine.string("nowhere", defaultValue: nil, args: []), "nowhere")          // key
    }

    func testFormattingAndNormalisation() {
        let engine = makeEngine()
        XCTAssertEqual(engine.string("greeting", defaultValue: nil, args: ["Ana"]), "Hola Ana")
        // Broken translation falls back to the base value instead of crashing.
        XCTAssertEqual(engine.string("broken", defaultValue: nil, args: [5]), "Broken 5")
    }

    func testPlurals() {
        let engine = makeEngine()
        XCTAssertEqual(engine.pluralString("items", count: 1, defaultValue: nil, args: []), "1 artículo")
        XCTAssertEqual(engine.pluralString("items", count: 4, defaultValue: nil, args: []), "4 artículos")
        XCTAssertEqual(engine.pluralString("missing_plural", count: 2, defaultValue: "%d things", args: []), "2 things")
        // Plural value read as a plain string gives "other".
        XCTAssertEqual(engine.string("items", defaultValue: nil, args: []), "%d artículos")
    }

    func testArrays() {
        let engine = makeEngine()
        XCTAssertEqual(engine.stringArray("planets"), ["Mercury", "Venus"])
        XCTAssertEqual(engine.string("planets.1", defaultValue: nil, args: []), "Venus")
    }

    func testOverrideAndSetLanguage() {
        let engine = makeEngine(preferred: ["es"], override: "en")
        XCTAssertEqual(engine.string("title", defaultValue: nil, args: []), "Hello")
        let exp = expectation(description: "change")
        engine.onChange = { snap in if snap.resolvedLanguage == "es" { exp.fulfill() } }
        engine.setLanguage(nil)
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(engine.string("title", defaultValue: nil, args: []), "Hola")
    }

    func testBundleLookupForSwizzledMainBundle() {
        let engine = makeEngine()
        XCTAssertEqual(engine.bundleLookup("greeting", original: { nil }), "Hola %1$@")
        XCTAssertNil(engine.bundleLookup("items", original: { nil }), "plural values defer to compiled stringsdict")
        XCTAssertNil(engine.bundleLookup("unknown", original: { "x" }))
    }

    func testNoCacheFallsBackToCompiled() {
        let engine = makeEngine(compiled: ["title": "App title"], store: InMemoryBundleStore())
        XCTAssertEqual(engine.string("title", defaultValue: nil, args: []), "App title")
    }

    // MARK: Draft mode

    func testDraftModeRecordsKeysMissingFromBase() {
        let engine = makeEngine(compiled: ["new_key": "New value"], draftMode: true)
        _ = engine.string("title", defaultValue: nil, args: [])
        _ = engine.string("new_key", defaultValue: nil, args: [])
        _ = engine.string("with_default", defaultValue: "Fallback", args: [])
        _ = engine.string("no_local_value", defaultValue: nil, args: [])
        XCTAssertEqual(engine.reporter?.pendingKeys, ["new_key", "with_default"])
    }

    func testDraftModeFlushPostsBatch() async throws {
        let transport = MockTransport()
        let exp = expectation(description: "posted")
        var body: [String: Any] = [:]
        transport.handlers["/v1/sdk/p/missing"] = { req in
            body = (try? JSONSerialization.jsonObject(with: req.httpBody ?? Data())) as? [String: Any] ?? [:]
            exp.fulfill()
            return (200, [:], Data(#"{"created":1,"ignored":0}"#.utf8))
        }
        let engine = makeEngine(compiled: ["new_key": "New value"], transport: transport, draftMode: true)
        _ = engine.string("new_key", defaultValue: nil, args: [])
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["language"] as? String, "en")
        let keys = body["keys"] as? [[String: Any]]
        XCTAssertEqual(keys?.first?["key"] as? String, "new_key")
        XCTAssertEqual(keys?.first?["value"] as? String, "New value")
    }

    // MARK: Refresh

    func testRefreshDownloadsResolvedAndBaseThenHonoursETag() async throws {
        let transport = MockTransport()
        let m = manifest(version: 4)
        var etagSeen: String?
        transport.handlers["/v1/sdk/p/manifest"] = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Api-Key"), "pk_test")
            etagSeen = req.value(forHTTPHeaderField: "If-None-Match")
            if etagSeen == "\"v4\"" { return (304, [:], Data()) }
            return (200, ["ETag": "\"v4\""], try! JSONEncoder().encode(m))
        }
        let es4 = TranslationBundle(projectId: "p", version: 4, language: "es", strings: ["title": .string("Hola v4")])
        let en4 = TranslationBundle(projectId: "p", version: 4, language: "en", strings: ["title": .string("Hello v4")])
        transport.handlers["/v1/sdk/p/bundles/4/es.json"] = { _ in (200, [:], try! JSONEncoder().encode(es4)) }
        transport.handlers["/v1/sdk/p/bundles/4/en.json"] = { _ in (200, [:], try! JSONEncoder().encode(en4)) }

        let store = InMemoryBundleStore()
        let engine = makeEngine(store: store, transport: transport)
        XCTAssertEqual(engine.string("title", defaultValue: nil, args: []), "title")

        var notified = 0
        engine.onChange = { _ in notified += 1 }
        await engine.refresh(force: false)
        XCTAssertNil(etagSeen)
        XCTAssertEqual(engine.string("title", defaultValue: nil, args: []), "Hola v4")
        XCTAssertEqual(store.loadManifest()?.etag, "\"v4\"")
        XCTAssertEqual(notified, 1)

        // Within refresh interval: no request.
        await engine.refresh(force: false)
        XCTAssertEqual(transport.count(path: "/v1/sdk/p/manifest"), 1)

        // Forced: conditional request, 304, no bundle downloads, no notification.
        await engine.refresh(force: true)
        XCTAssertEqual(etagSeen, "\"v4\"")
        XCTAssertEqual(transport.count(path: "/v1/sdk/p/bundles/4/es.json"), 1)
        XCTAssertEqual(notified, 1)
    }

    func testRefreshRejectsBundleWithWrongVersionAndKeepsCache() async {
        let transport = MockTransport()
        transport.handlers["/v1/sdk/p/manifest"] = { _ in (200, [:], try! JSONEncoder().encode(self.manifest(version: 5))) }
        let wrong = TranslationBundle(projectId: "p", version: 4, language: "es", strings: ["title": .string("stale")])
        transport.handlers["/v1/sdk/p/bundles/5/es.json"] = { _ in (200, [:], try! JSONEncoder().encode(wrong)) }
        let engine = makeEngine(transport: transport)
        await engine.refresh(force: true)
        XCTAssertEqual(engine.string("title", defaultValue: nil, args: []), "Hola")
        XCTAssertEqual(engine.snapshot.cached?.manifest.version, 3)
    }

    func testNetworkFailureIsSwallowed() async {
        let engine = makeEngine(transport: MockTransport()) // every request → 404
        await engine.refresh(force: true)
        XCTAssertEqual(engine.string("title", defaultValue: nil, args: []), "Hola")
    }

    func testDiskStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DiskBundleStore(projectId: "p", rootDirectory: dir)
        let cached = CachedManifest(manifest: manifest(), etag: "\"v3\"", lastCheck: Date(timeIntervalSince1970: 1000))
        try store.saveManifest(cached)
        try store.saveBundle(es, data: JSONEncoder().encode(es))
        XCTAssertEqual(store.loadManifest(), cached)
        XCTAssertEqual(store.loadBundle(language: "ES"), es)
        XCTAssertNil(store.loadBundle(language: "fr"))
        // Engine loads cache synchronously at init.
        let engine = makeEngine(store: store)
        XCTAssertEqual(engine.string("title", defaultValue: nil, args: []), "Hola")
    }
}
