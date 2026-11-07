import Testing
@testable import Viewing

@Suite struct JSONPathTests {
    static let doc = try! JSONNode.parse(#"""
    {"store":{"book":[
        {"title":"A","price":8.95,"tags":["x"]},
        {"title":"B","price":12.99,"isbn":"123"},
        {"title":"C","price":8.99,"isbn":null}
      ],"odd key":{"title":"D"}},
     "count":3}
    """#)

    func paths(_ q: String) throws -> [String] { try JSONPath(q).evaluate(Self.doc).map(\.path) }
    func values(_ q: String) throws -> [JSONNode] { try JSONPath(q).evaluate(Self.doc).map(\.node) }

    @Test func rootAndChildren() throws {
        #expect(try paths("$") == ["$"])
        #expect(try values("$.count") == [.number("3")])
        #expect(try values("$['store']['book'][1].title") == [.string("B")])
        #expect(try paths("$.store['odd key'].title") == ["$.store['odd key'].title"])
    }

    @Test func indexesAndSlices() throws {
        #expect(try values("$.store.book[-1].title") == [.string("C")])
        #expect(try values("$.store.book[0,2].title") == [.string("A"), .string("C")])
        #expect(try values("$.store.book[1:].title") == [.string("B"), .string("C")])
        #expect(try values("$.store.book[:1].title") == [.string("A")])
        #expect(try values("$.store.book[5]").isEmpty)
    }

    @Test func wildcardsAndRecursiveDescent() throws {
        #expect(try values("$.store.book[*].title").count == 3)
        #expect(try values("$.store.*").count == 2)
        #expect(try values("$..title") == [.string("A"), .string("B"), .string("C"), .string("D")])
        #expect(try paths("$..tags[0]") == ["$.store.book[0].tags[0]"])
    }

    @Test func filters() throws {
        #expect(try values("$.store.book[?(@.price < 10)].title") == [.string("A"), .string("C")])
        #expect(try values("$.store.book[?(@.title == 'B')].price") == [.number("12.99")])
        #expect(try values("$.store.book[?(@.isbn)].title") == [.string("B"), .string("C")])
        #expect(try values("$.store.book[?(@.isbn == null)].title") == [.string("C")])
        #expect(try values("$.store.book[?(@.tags[0] != 'y')].title") == [.string("A")])
    }

    @Test func syntaxErrorsHavePositions() {
        #expect(throws: JSONPath.SyntaxError(message: "A query starts with '$'", offset: 0)) { try JSONPath("store") }
        #expect(throws: JSONPath.SyntaxError.self) { try JSONPath("$.store[") }
        #expect(throws: JSONPath.SyntaxError.self) { try JSONPath("$[?(@.a == )]") }
        #expect(throws: JSONPath.SyntaxError.self) { try JSONPath("$.a b") }
    }
}
