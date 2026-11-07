import Foundation
import ProxyModel
import Testing
@testable import Viewing

@Suite struct CodeGeneratorTests {
    static let post = ComposedRequest(method: "POST", url: "https://api.test/v1/it's?a=1",
                                      headers: [HeaderField(name: "Content-Type", value: "application/json"),
                                                HeaderField(name: "X-Tag", value: "a"), HeaderField(name: "x-tag", value: "b")],
                                      body: Data(#"{"name":"O'Neil","price":"$5"}"#.utf8))

    @Test func curlEscapesSingleQuotesAndSkipsDefaultGet() {
        #expect(CodeGenerator.generate(.init(url: "https://a.test/"), language: .curl) == "curl 'https://a.test/'")
        #expect(CodeGenerator.generate(Self.post, language: .curl) == #"""
        curl -X POST \
          'https://api.test/v1/it'\''s?a=1' \
          -H 'Content-Type: application/json' \
          -H 'X-Tag: a' \
          -H 'x-tag: b' \
          --data-raw '{"name":"O'\''Neil","price":"$5"}'
        """#)
    }

    @Test func swiftKeepsDuplicateHeadersAndEscapes() {
        let code = CodeGenerator.generate(Self.post, language: .swift)
        #expect(code.contains(#"request.addValue("a", forHTTPHeaderField: "X-Tag")"#))
        #expect(code.contains(#"request.addValue("b", forHTTPHeaderField: "x-tag")"#))
        #expect(code.contains(#"request.httpBody = Data("{\"name\":\"O'Neil\",\"price\":\"$5\"}".utf8)"#))
        #expect(code.hasPrefix(#"var request = URLRequest(url: URL(string: "https://api.test/v1/it's?a=1")!)"#))
    }

    @Test func pythonAndJavaScriptMergeDuplicateHeaders() {
        let py = CodeGenerator.generate(Self.post, language: .python)
        #expect(py.contains(#"        "X-Tag": "a, b","#))
        #expect(py.contains(#"    data="{\"name\":\"O'Neil\",\"price\":\"$5\"}".encode("utf-8"),"#))
        let js = CodeGenerator.generate(Self.post, language: .javascript)
        #expect(js.contains(#"    "X-Tag": "a, b","#))
        #expect(js.hasPrefix(#"const response = await fetch("https://api.test/v1/it's?a=1", {"#))
    }

    @Test func kotlinEscapesDollarAndUsesMediaType() {
        let kt = CodeGenerator.generate(Self.post, language: .kotlin)
        #expect(kt.contains(#".method("POST", "{\"name\":\"O'Neil\",\"price\":\"\$5\"}".toRequestBody("application/json".toMediaType()))"#))
        #expect(kt.contains("import okhttp3.RequestBody.Companion.toRequestBody"))
        let get = CodeGenerator.generate(.init(url: "https://a.test/"), language: .kotlin)
        #expect(get.contains(#".method("GET", null)"#))
        #expect(!get.contains("toMediaType"))
    }

    @Test func binaryBodiesAreReadFromAFile() {
        let bin = ComposedRequest(method: "PUT", url: "https://a.test/f", body: Data([0xFF, 0x00, 0xFE]))
        #expect(CodeGenerator.generate(bin, language: .curl).hasSuffix("--data-binary @body.bin"))
        for language in CodeLanguage.allCases where language != .curl {
            let code = CodeGenerator.generate(bin, language: language)
            #expect(code.contains("3 bytes of binary body omitted"), "\(language)")
            #expect(code.contains("body.bin"), "\(language)")
        }
    }

    @Test func newlinesAreEscapedInEveryQuotedLanguage() {
        let r = ComposedRequest(method: "POST", url: "https://a.test/", body: Data("a\nb".utf8))
        for language in [CodeLanguage.swift, .python, .javascript, .kotlin] {
            #expect(CodeGenerator.generate(r, language: language).contains(#""a\nb""#), "\(language)")
        }
    }
}
