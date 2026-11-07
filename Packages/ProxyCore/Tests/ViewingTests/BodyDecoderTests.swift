import Foundation
import Testing
@testable import Viewing

@Suite struct BodyDecoderTests {
    static let text = String(repeating: #"{"greeting":"hello","n":[1,2,3]}"#, count: 4)

    /// Fixtures made with gzip, zlib, brotli and the zstd CLI from `text`.
    static let fixtures: [(encoding: String, base64: String)] = [
        ("gzip", "H4sIAAAAAAAC/6tWSi9KTS3JzEtXslLKSM3JyVfSUcpTsoo21DHSMY6traaxPABIDUHYgAAAAA=="),
        ("deflate", "eJyrVkovSk0tycxLV7JSykjNyclX0lHKU7KKNtQx0jGOra2msTwAKSonhQ=="),
        ("deflate", "q1ZKL0pNLcnMS1eyUspIzcnJV9JRylOyijbUMdIxjq2tprE8AA=="),
        ("br", "G38A+I3TFfcjnKwiKLelfqFta9H8TGFMEJuYLDpdgWG8YP3II93VSUxVbdA0jIs/"),
        ("zstd", "KLUv/QBYRQEABAJ7ImdyZWV0aW5nIjoiaGVsbG8iLCJuIjpbMSwyLDNdfQEA6DGpJw=="),
        ("gzip, br", "CxuAH4sIAAAAAAAC/6tWSi9KTS3JzEtXslLKSM3JyVfSUcpTsoo21DHSMY6traaxPABIDUHYgAAAAAM="),
    ]

    @Test(arguments: fixtures)
    func decodesEachEncoding(_ fixture: (encoding: String, base64: String)) {
        let raw = Data(base64Encoded: fixture.base64)!
        let out = BodyDecoder.decode(raw, contentEncoding: fixture.encoding)
        #expect(out.error == nil)
        #expect(String(decoding: out.data, as: UTF8.self) == Self.text)
        #expect(out.rawSize == raw.count)
        #expect(!out.truncated)
    }

    @Test func undoesEncodingsInReverseOrder() {
        let out = BodyDecoder.decode(Data(base64Encoded: Self.fixtures[5].base64)!, contentEncoding: "gzip, br")
        #expect(out.appliedEncodings == ["br", "gzip"])
    }

    @Test func identityAndMissingHeaderPassThrough() {
        let raw = Data("plain".utf8)
        #expect(BodyDecoder.decode(raw, contentEncoding: nil).data == raw)
        #expect(BodyDecoder.decode(raw, contentEncoding: "identity").appliedEncodings.isEmpty)
    }

    @Test func unknownEncodingKeepsRawBytes() {
        let raw = Data("abc".utf8)
        let out = BodyDecoder.decode(raw, contentEncoding: "compress")
        #expect(out.data == raw)
        #expect(out.error?.contains("compress") == true)
    }

    @Test func corruptDataReportsErrorAndKeepsRaw() {
        let raw = Data("this is not gzip at all, sorry".utf8)
        let out = BodyDecoder.decode(raw, contentEncoding: "gzip")
        #expect(out.data == raw)
        #expect(out.error != nil)
        let z = BodyDecoder.decode(raw, contentEncoding: "zstd")
        #expect(z.data == raw)
        #expect(z.error != nil)
    }

    @Test func truncatedInputDecodesThePrefixWithoutError() {
        let full = Data(base64Encoded: Self.fixtures[4].base64)!
        let out = BodyDecoder.decode(full.prefix(full.count - 6), contentEncoding: "zstd", inputTruncated: true)
        #expect(out.truncated)
        #expect(out.error == nil)
        #expect(Self.text.hasPrefix(String(decoding: out.data, as: UTF8.self)))
    }

    @Test func cutOffGzipIsAnErrorOnlyWhenTheInputWasComplete() {
        let full = Data(base64Encoded: Self.fixtures[0].base64)!
        let cut = full.prefix(full.count - 20)
        let prefix = BodyDecoder.decode(cut, contentEncoding: "gzip", inputTruncated: true)
        #expect(prefix.error == nil)
        #expect(prefix.truncated)
        #expect(Self.text.hasPrefix(String(decoding: prefix.data, as: UTF8.self)))
        #expect(BodyDecoder.decode(cut, contentEncoding: "gzip").error != nil)
    }

    @Test func outputIsCappedAgainstBombs() throws {
        let zeros = Data(count: 4 * 1024 * 1024)
        let bomb = try (zeros as NSData).compressed(using: .zlib) as Data // raw deflate
        #expect(bomb.count < 64 * 1024)
        let out = BodyDecoder.decode(bomb, contentEncoding: "deflate", maxOutput: 1024 * 1024)
        #expect(out.data.count == 1024 * 1024)
        #expect(out.truncated)
    }
}
