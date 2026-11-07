import Foundation
import ProxyModel
import Testing
@testable import Viewing

@Suite struct ContentSnifferTests {
    func sniff(_ type: String?, _ bytes: [UInt8]) -> BodyKind { ContentSniffer.sniff(contentType: type, data: Data(bytes)) }
    func sniff(_ type: String?, _ text: String) -> BodyKind { sniff(type, Array(text.utf8)) }

    @Test func headerWins() {
        #expect(sniff("application/json; charset=utf-8", "nope") == .json)
        #expect(sniff("application/vnd.api+json", "{}") == .json)
        #expect(sniff("text/html", "x") == .html)
        #expect(sniff("application/xml", "x") == .xml)
        #expect(sniff("image/svg+xml", "<svg/>") == .xml)
        #expect(sniff("application/x-www-form-urlencoded", "a=1") == .form)
        #expect(sniff("multipart/form-data; boundary=\"abc 1\"", "") == .multipart(boundary: "abc 1"))
        #expect(sniff("text/css", "a{}") == .text)
        #expect(sniff("application/javascript", "x()") == .text)
    }

    @Test func imageFormatComesFromMagicBytes() {
        #expect(sniff("image/png", [0xFF, 0xD8, 0xFF, 0xE0]) == .image(format: "jpeg"))
        #expect(sniff(nil, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]) == .image(format: "png"))
        #expect(sniff("image/avif", [0, 1, 2]) == .image(format: "avif"))
        #expect(sniff(nil, Array("RIFF\0\0\0\0WEBPVP8 ".utf8)) == .image(format: "webp"))
    }

    @Test func bytesDecideWithoutUsefulHeader() {
        #expect(sniff(nil, "  \n{\"a\":1}") == .json)
        #expect(sniff("application/octet-stream", "[1,2]") == .json)
        #expect(sniff(nil, "<!DOCTYPE html><html>") == .html)
        #expect(sniff(nil, "<?xml version=\"1.0\"?>") == .xml)
        #expect(sniff(nil, "hello world") == .text)
        #expect(sniff(nil, [0, 1, 2, 3, 0xFE, 0x00, 0x10]) == .binary)
        #expect(sniff(nil, "") == .text)
    }

    @Test func multipartWithoutBoundaryFallsBackToBytes() {
        #expect(sniff("multipart/form-data", "plain") == .text)
    }

    @Test func categoryForFilter() {
        #expect(ContentCategory(contentType: "application/problem+json") == .json)
        #expect(ContentCategory(contentType: "TEXT/HTML; charset=utf-8") == .html)
        #expect(ContentCategory(contentType: "image/webp") == .image)
        #expect(ContentCategory(contentType: nil) == .other)
    }

    @Test func formAndQueryParsing() {
        let form = FormParser.parse("b=x+y&a=%E2%9C%93&empty=&flag")
        #expect(form.map(\.name) == ["b", "a", "empty", "flag"])
        #expect(form.map(\.value) == ["x y", "✓", "", ""])
        let q = FormParser.query(of: "https://h.test/p?id=7&q=a%20b#frag")
        #expect(q.map(\.name) == ["id", "q"])
        #expect(q.last?.value == "a b")
        #expect(FormParser.query(of: "https://h.test/p").isEmpty)
    }
}
