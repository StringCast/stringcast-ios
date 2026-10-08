import XCTest
@testable import StringCast

final class BundleDecodingTests: XCTestCase {
    let json = """
    {
      "projectId": "p_8f3k2j",
      "version": 7,
      "language": "es",
      "publishedAt": "2026-10-08T15:04:05.000Z",
      "strings": {
        "welcome_title": "Bienvenido",
        "items_count": { "one": "%d artículo", "other": "%d artículos" },
        "planets": ["Mercurio", "Venus"],
        "bad_number": 42,
        "bad_plural": { "foo": "bar" }
      }
    }
    """

    func testDecodesAllValueTypesAndSkipsMalformed() throws {
        let b = try JSONDecoder().decode(TranslationBundle.self, from: Data(json.utf8))
        XCTAssertEqual(b.projectId, "p_8f3k2j")
        XCTAssertEqual(b.version, 7)
        XCTAssertEqual(b.language, "es")
        XCTAssertEqual(b.strings["welcome_title"], .string("Bienvenido"))
        XCTAssertEqual(b.strings["items_count"], .plural(["one": "%d artículo", "other": "%d artículos"]))
        XCTAssertEqual(b.strings["planets"], .array(["Mercurio", "Venus"]))
        XCTAssertNil(b.strings["bad_number"])
        XCTAssertNil(b.strings["bad_plural"])
        XCTAssertEqual(b.strings.count, 3)
    }

    func testArrayElementKeys() throws {
        let b = try JSONDecoder().decode(TranslationBundle.self, from: Data(json.utf8))
        XCTAssertEqual(b.value(for: "planets.1"), .string("Venus"))
        XCTAssertNil(b.value(for: "planets.2"))
        XCTAssertNil(b.value(for: "planets.x"))
    }

    func testRoundTrip() throws {
        let b = try JSONDecoder().decode(TranslationBundle.self, from: Data(json.utf8))
        let again = try JSONDecoder().decode(TranslationBundle.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(b, again)
    }

    func testManifestDecoding() throws {
        let m = try JSONDecoder().decode(Manifest.self, from: Data("""
        {"projectId":"p","version":7,"publishedAt":"2026-10-08T15:04:05.000Z","baseLanguage":"en",
         "languages":[{"code":"en","url":"http://x/en.json","hash":"sha256-abc","keyCount":120},
                      {"code":"pt-BR","url":"http://x/pt-BR.json","hash":"sha256-def","keyCount":118}]}
        """.utf8))
        XCTAssertEqual(m.version, 7)
        XCTAssertEqual(m.entry(for: "pt_br")?.code, "pt-BR")
        let empty = try JSONDecoder().decode(Manifest.self, from: Data(#"{"projectId":"p","version":0,"publishedAt":null,"baseLanguage":"en","languages":[]}"#.utf8))
        XCTAssertEqual(empty.version, 0)
        XCTAssertTrue(empty.languages.isEmpty)
    }

    func testHashVerification() {
        let data = Data("hello".utf8)
        // sha256("hello")
        let hex = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        XCTAssertTrue(APIClient.verify(data: data, hash: "sha256-" + hex))
        XCTAssertTrue(APIClient.verify(data: data, hash: "sha256-LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ="))
        XCTAssertFalse(APIClient.verify(data: data, hash: "sha256-" + String(repeating: "0", count: 64)))
        XCTAssertTrue(APIClient.verify(data: data, hash: "md5-whatever"))
    }
}
