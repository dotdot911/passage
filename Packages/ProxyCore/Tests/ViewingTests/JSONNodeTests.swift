import Foundation
import Testing
@testable import Viewing

@Suite struct JSONNodeTests {
    @Test func keepsKeyOrderAndDuplicates() throws {
        let node = try JSONNode.parse(#"{"z":1,"a":2,"z":3}"#)
        guard case .object(let members) = node else { Issue.record("not an object"); return }
        #expect(members.map(\.key) == ["z", "a", "z"])
        #expect(node.serialized() == #"{"z":1,"a":2,"z":3}"#)
    }

    @Test func keepsNumberSpelling() throws {
        let node = try JSONNode.parse("[12345678901234567890, 1.50, -0.0e+10]")
        #expect(node == .array([.number("12345678901234567890"), .number("1.50"), .number("-0.0e+10")]))
    }

    @Test func parsesEveryValueKind() throws {
        let node = try JSONNode.parse(#" {"s":"a\"b\\c\n\u00e9\ud83d\ude00","t":true,"f":false,"n":null,"e":[],"o":{}} "#)
        #expect(node == .object([
            JSONMember("s", .string("a\"b\\c\né😀")), JSONMember("t", .bool(true)), JSONMember("f", .bool(false)),
            JSONMember("n", .null), JSONMember("e", .array([])), JSONMember("o", .object([])),
        ]))
    }

    @Test func prettyPrintsWithTwoSpaces() throws {
        let node = try JSONNode.parse(#"{"a":[1,{"b":"x"}],"c":{}}"#)
        #expect(node.serialized(pretty: true) == """
        {
          "a": [
            1,
            {
              "b": "x"
            }
          ],
          "c": {}
        }
        """)
    }

    @Test func escapesWhenSerializing() {
        #expect(JSONNode.string("q\"\u{1}\t").serialized() == #""q\"\u0001\t""#)
    }

    @Test func reportsErrorsWithOffset() {
        #expect(throws: JSONParseError(message: "Expected ',' or '}'", offset: 7)) { try JSONNode.parse(#"{"a":1 "b":2}"#) }
        #expect(throws: JSONParseError.self) { try JSONNode.parse("[1,]") }
        #expect(throws: JSONParseError.self) { try JSONNode.parse("01") }
        #expect(throws: JSONParseError.self) { try JSONNode.parse("{\"a\":1} x") }
        #expect(throws: JSONParseError.self) { try JSONNode.parse("\"abc") }
    }

    @Test func limitsDepth() throws {
        let ok = String(repeating: "[", count: JSONNode.maxDepth) + String(repeating: "]", count: JSONNode.maxDepth)
        _ = try JSONNode.parse(ok)
        let deep = "[" + ok + "]"
        #expect(throws: JSONParseError.self) { try JSONNode.parse(deep) }
    }

    @Test func skipsByteOrderMark() throws {
        #expect(try JSONNode.parse(Data([0xEF, 0xBB, 0xBF]) + Data("1".utf8)) == .number("1"))
    }
}
