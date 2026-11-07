import Foundation
import ProxyModel
import Testing
@testable import Viewing

@Suite struct BodyPreviewTests {
    @Test func decodesThenSniffs() {
        let gz = Data(base64Encoded: BodyDecoderTests.fixtures[0].base64)!
        let p = BodyPreview(raw: gz, storedSize: gz.count, headers: [
            HeaderField(name: "content-encoding", value: "gzip"),
            HeaderField(name: "Content-Type", value: "application/octet-stream"),
        ])
        #expect(p.kind == .json)
        #expect(p.decoded.data.count == BodyDecoderTests.text.utf8.count)
        #expect(p.summary?.hasPrefix("gzip · 55 bytes → ") == true)
    }

    @Test func parsesOnceForEachKind() {
        let json = BodyPreview(raw: Data(#"{"b":1,"a":2}"#.utf8), storedSize: 13, headers: [])
        #expect(json.json?.childCount == 2)
        #expect(json.fullText() == "{\n  \"b\": 1,\n  \"a\": 2\n}")
        let broken = BodyPreview(raw: Data("{nope".utf8), storedSize: 5, headers: [HeaderField(name: "Content-Type", value: "application/json")])
        #expect(broken.json == nil && broken.inlineText == "{nope")
        let form = BodyPreview(raw: Data("a=1&b=2".utf8), storedSize: 7,
                               headers: [HeaderField(name: "Content-Type", value: "application/x-www-form-urlencoded")])
        #expect(form.form.map(\.name) == ["a", "b"])
        let multipart = BodyPreview(raw: Data("--b\r\nContent-Type: application/json\r\n\r\n[1]\r\n--b--".utf8), storedSize: 40,
                                    headers: [HeaderField(name: "Content-Type", value: "multipart/form-data; boundary=b")])
        #expect(multipart.partPreviews.first?.json == .array([.number("1")]))
    }

    @Test func inlineTextIsCut() {
        let big = Data(repeating: UInt8(ascii: "x"), count: BodyPreview.maxInlineTextBytes + 10)
        let p = BodyPreview(raw: big, storedSize: big.count, headers: [])
        #expect(p.inlineTextTruncated)
        #expect(p.inlineText.utf8.count == BodyPreview.maxInlineTextBytes)
        #expect(p.fullText().utf8.count == big.count)
    }

    @Test func plainBodyHasNoSummary() {
        let p = BodyPreview(raw: Data("hi".utf8), storedSize: 2, headers: [])
        #expect(p.summary == nil)
        #expect(p.kind == .text)
    }

    @Test func cutOffBodyIsMarkedTruncated() {
        let p = BodyPreview(raw: Data("abc".utf8), storedSize: 10_000_000, headers: [])
        #expect(p.decoded.truncated)
        #expect(p.summary?.contains("first 3 bytes") == true)
    }

    @Test func decodeErrorIsSummarised() {
        let p = BodyPreview(raw: Data("nope".utf8), storedSize: 4, headers: [HeaderField(name: "Content-Encoding", value: "br")])
        #expect(p.summary?.contains("not decoded: br") == true)
    }
}
