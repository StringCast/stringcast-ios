import XCTest
@testable import StringCast

final class LocalStringsReaderTests: XCTestCase {
    func testStringsText() {
        let parsed = LocalStringsReader.parseStrings(text: "/* c */\n\"a\" = \"A\";\n\"b\" = \"B %@\";")
        XCTAssertEqual(parsed, ["a": .string("A"), "b": .string("B %@")])
    }

    func testStringsDictExpansion() {
        let dict: [String: Any] = [
            "items_count": [
                "NSStringLocalizedFormatKey": "You have %#@items@",
                "items": [
                    "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                    "NSStringFormatValueTypeKey": "d",
                    "one": "%d item",
                    "other": "%d items",
                ],
            ],
        ]
        XCTAssertEqual(LocalStringsReader.parseStringsDict(dict)["items_count"],
                       .plural(["one": "You have %d item", "other": "You have %d items"]))
    }

    func testXCStrings() {
        let json = """
        {"sourceLanguage":"en","version":"1.0","strings":{
          "hello":{"localizations":{"en":{"stringUnit":{"state":"translated","value":"Hello"}}}},
          "Implicit key":{},
          "skip":{"shouldTranslate":false},
          "files":{"localizations":{"en":{"variations":{"plural":{
             "one":{"stringUnit":{"state":"translated","value":"%lld file"}},
             "other":{"stringUnit":{"state":"translated","value":"%lld files"}}}}}}}
        }}
        """
        let r = LocalStringsReader.parseXCStrings(Data(json.utf8), language: "en")
        XCTAssertEqual(r.sourceLanguage, "en")
        XCTAssertEqual(r.entries["hello"], .string("Hello"))
        XCTAssertEqual(r.entries["Implicit key"], .string("Implicit key"))
        XCTAssertNil(r.entries["skip"])
        XCTAssertEqual(r.entries["files"], .plural(["one": "%lld file", "other": "%lld files"]))
    }

    func testMainBundleInterceptorOnlyTouchesLocalizableTable() {
        XCTAssertTrue(StringCastMainBundle.isDefaultTable(nil))
        XCTAssertTrue(StringCastMainBundle.isDefaultTable(""))
        XCTAssertTrue(StringCastMainBundle.isDefaultTable("Localizable"))
        XCTAssertFalse(StringCastMainBundle.isDefaultTable("InfoPlist"))
        XCTAssertFalse(StringCastMainBundle.isDefaultTable("Main"))
    }
}
