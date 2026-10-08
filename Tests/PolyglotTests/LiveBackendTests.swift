import XCTest
@testable import Polyglot

/// Opt-in smoke test against a running local backend (`npm run seed && npm run dev`):
/// `POLYGLOT_LIVE=1 swift test --filter LiveBackendTests`. Read-only (no /missing posts).
final class LiveBackendTests: XCTestCase {
    func testFetchesAndVerifiesRealBundles() async throws {
        guard ProcessInfo.processInfo.environment["POLYGLOT_LIVE"] == "1" else {
            throw XCTSkip("set POLYGLOT_LIVE=1 to run against http://localhost:8787")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = PolyglotConfig(projectId: "p_demo", sdkKey: "pk_demo_local",
                                    baseURL: URL(string: "http://localhost:8787")!, draftMode: false)
        let store = DiskBundleStore(projectId: "p_demo", rootDirectory: dir)
        let engine = PolyglotEngine(config: config, store: store,
                                    transport: URLSessionTransport(session: .shared),
                                    appStrings: { _ in nil }, preferredLanguages: { ["es-ES"] })
        await engine.refresh(force: true)
        let snap = engine.snapshot
        XCTAssertGreaterThan(snap.cached?.manifest.version ?? 0, 0)
        XCTAssertEqual(snap.resolvedLanguage, "es")
        XCTAssertNotNil(snap.active, "es bundle downloaded + hash verified")
        XCTAssertNotNil(snap.base, "base bundle downloaded")
        print("live: v\(snap.cached!.manifest.version) es keys=\(snap.active!.strings.keys.sorted())")
        // Second engine reads the disk cache synchronously.
        let cachedEngine = PolyglotEngine(config: config, store: DiskBundleStore(projectId: "p_demo", rootDirectory: dir),
                                          transport: URLSessionTransport(session: .shared),
                                          appStrings: { _ in nil }, preferredLanguages: { ["es-ES"] })
        XCTAssertEqual(cachedEngine.snapshot.active, snap.active)
        // 304 path.
        await engine.refresh(force: true)
        XCTAssertEqual(engine.snapshot.cached?.etag, snap.cached?.etag)
        if let key = snap.active?.strings.keys.sorted().first {
            print("live: \(key) → \(engine.string(key, defaultValue: nil, args: []))")
        }
    }
}
