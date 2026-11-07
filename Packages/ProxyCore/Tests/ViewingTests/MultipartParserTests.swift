import Foundation
import ProxyModel
import Testing
@testable import Viewing

@Suite struct MultipartParserTests {
    @Test func parsesCRLFBodyWithPreambleAndBinaryPart() {
        var body = Data("preamble\r\n--XyZ\r\nContent-Disposition: form-data; name=\"field\"\r\n\r\nvalue\r\n".utf8)
        body += Data("--XyZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body += Data([0x00, 0x0D, 0x0A, 0xFF])
        body += Data("\r\n--XyZ--\r\nepilogue".utf8)
        let out = MultipartParser.parse(body, boundary: "XyZ")
        #expect(!out.incomplete)
        #expect(out.parts.count == 2)
        #expect(out.parts[0].name == "field")
        #expect(out.parts[0].data == Data("value".utf8))
        #expect(out.parts[1].filename == "a.bin")
        #expect(out.parts[1].contentType == "application/octet-stream")
        #expect(out.parts[1].data == Data([0x00, 0x0D, 0x0A, 0xFF]))
    }

    @Test func acceptsBareLineFeeds() {
        let body = Data("--b\nContent-Type: text/plain\n\nhello\n--b--\n".utf8)
        let out = MultipartParser.parse(body, boundary: "b")
        #expect(out.parts.map(\.data) == [Data("hello".utf8)])
        #expect(out.parts[0].headers == [HeaderField(name: "Content-Type", value: "text/plain")])
    }

    @Test func missingClosingBoundaryIsIncomplete() {
        let body = Data("--b\r\n\r\none\r\n--b\r\n\r\ntwo, cut off".utf8)
        let out = MultipartParser.parse(body, boundary: "b")
        #expect(out.incomplete)
        #expect(out.parts.map(\.data) == [Data("one".utf8), Data("two, cut off".utf8)])
    }

    @Test func boundaryTextInsideALineIsNotADelimiter() {
        let body = Data("--b\r\n\r\nsee --b here\r\n--b--".utf8)
        #expect(MultipartParser.parse(body, boundary: "b").parts.map(\.data) == [Data("see --b here".utf8)])
    }

    @Test func noDelimiterAtAll() {
        let out = MultipartParser.parse(Data("nothing".utf8), boundary: "b")
        #expect(out.parts.isEmpty)
        #expect(out.incomplete)
    }
}
