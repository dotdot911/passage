import Foundation
import ProxyModel
import Testing
@testable import Viewing

@Suite struct GraphQLOperationTests {
    func post(_ json: String, contentType: String? = "application/json") -> String? {
        GraphQLOperation.detect(method: "POST", url: "https://api.test/graphql", contentType: contentType, body: Data(json.utf8))
    }

    @Test func namesFromOperationNameOrQueryText() {
        #expect(post(#"{"query":"query GetUser($id: ID!) { user(id: $id) { name } }"}"#) == "query GetUser")
        #expect(post(#"{"query":"mutation { like }","operationName":"Like"}"#) == "mutation Like")
        #expect(post(#"{"query":"subscription OnMessage { message { id } }"}"#) == "subscription OnMessage")
        #expect(post(#"{"query":"{ me { id } }"}"#) == "query (anonymous)")
        #expect(post(#"{"query":"query { me { id } }","operationName":""}"#) == "query (anonymous)")
        #expect(post(#"{"query":"  # comment\n query\n  Feed\n { feed }"}"#) == "query Feed")
    }

    @Test func picksTheNamedOperationInAMultiOperationDocument() {
        let doc = "fragment F on User { id } query A { a } mutation B { b ...F }"
        let body = #"{"query":"\#(doc)","operationName":"B"}"#
        #expect(post(body) == "mutation B")
        #expect(post(#"{"query":"\#(doc)"}"#) == "query A")
        #expect(post(#"{"query":"query Q($v: In = {query: 1}) @dir { x }"}"#) == "query Q")
    }

    @Test func batches() {
        let three = #"[{"query":"query A { a }"},{"query":"{ b }","operationName":"B"},{"query":"mutation C { c }"}]"#
        #expect(post(three) == "batch (3): A, B, C")
        let four = #"[{"query":"query A { a }"},{"query":"{ b }"},{"query":"query C { c }"},{"query":"query D { d }"}]"#
        #expect(post(four) == "batch (4): A, (anonymous), C, …")
        #expect(post("[]") == nil)
        #expect(post(#"[{"query":"query A { a }"}, 1]"#) == nil)
    }

    @Test func getWithQueryParameter() {
        let url = "https://api.test/graphql?query=query%20Me%20%7B%20me%20%7D&variables=%7B%7D"
        #expect(GraphQLOperation.detect(method: "GET", url: url, contentType: nil, body: Data()) == "query Me")
        let plus = "https://api.test/graphql?query=query+Me+%7B+me+%7D&operationName=Me"
        #expect(GraphQLOperation.detect(method: "get", url: plus, contentType: nil, body: Data()) == "query Me")
        #expect(GraphQLOperation.detect(method: "GET", url: "https://shop.test/search?query=shoes", contentType: nil, body: Data()) == nil)
        #expect(GraphQLOperation.detect(method: "GET", url: "https://api.test/graphql", contentType: nil, body: Data()) == nil)
    }

    @Test func rejectsNonGraphQL() {
        #expect(post(#"{"query":"shoes"}"#) == nil)
        #expect(post(#"{"q":"{ a }"}"#) == nil)
        #expect(post(#"{"query":42}"#) == nil)
        #expect(post("not json") == nil)
        #expect(post(#"{"query":"{ a }"}"#, contentType: "text/plain") == nil)
        #expect(post(#"{"query":"{ a }"}"#, contentType: nil) == "query (anonymous)")
        #expect(post(#"{"query":"{ a }"}"#, contentType: "application/json; charset=utf-8") == "query (anonymous)")
        #expect(GraphQLOperation.detect(method: "PUT", url: "https://a.test", contentType: "application/json", body: Data(#"{"query":"{ a }"}"#.utf8)) == nil)
    }

    @Test func bodyOverLimitIsIgnored() {
        let padding = String(repeating: " ", count: GraphQLOperation.maxBodyBytes)
        #expect(post(#"{"query":"{ a }"}"# + padding) == nil)
    }

    @Test func mightBeGraphQL() {
        #expect(GraphQLOperation.mightBeGraphQL(method: "POST", url: "https://a.test/gql", contentType: "application/json"))
        #expect(GraphQLOperation.mightBeGraphQL(method: "POST", url: "https://a.test/gql", contentType: nil))
        #expect(!GraphQLOperation.mightBeGraphQL(method: "POST", url: "https://a.test/gql", contentType: "multipart/form-data; boundary=x"))
        #expect(GraphQLOperation.mightBeGraphQL(method: "GET", url: "https://a.test/gql?query=%7Ba%7D", contentType: nil))
        #expect(!GraphQLOperation.mightBeGraphQL(method: "GET", url: "https://a.test/gql?q=1", contentType: nil))
        #expect(!GraphQLOperation.mightBeGraphQL(method: "DELETE", url: "https://a.test/gql?query=1", contentType: nil))
    }

    @Test func tokenizerKeepsEveryToken() {
        let tokens = GraphQLToken.tokenize(#"query { a(s: "x, y\" }", b: """multi "" line""", n: -1.5e3) ...F # c"#)
        #expect(tokens.map(\.text) == ["query", "{", "a", "(", "s", ":", #""x, y\" }""#, ",", "b", ":", #""""multi "" line""""#,
                                       ",", "n", ":", "-1.5e3", ")", "...", "F", "# c"])
        #expect(tokens[6].kind == .string && tokens[10].kind == .blockString && tokens.last?.kind == .comment)
        #expect(GraphQLToken.tokenize("\u{FEFF}a ¿").map(\.text) == ["a", "¿"])
        #expect(GraphQLToken.tokenize(#""open"#).map(\.text) == [#""open"#])
    }
}

@Suite struct GraphQLFormatterTests {
    @Test func indentsSelections() {
        let q = #"query GetUser($id: ID!, $n: Int = 5) { user(id: $id, filter: {a: [1, 2]}) { name, ...UserFields friends(first: $n) @include(if: true) { edges { node { id } } } ... on Admin { level } } }"#
        #expect(GraphQLFormatter.format(q) == """
        query GetUser($id: ID!, $n: Int = 5) {
          user(id: $id, filter: {a: [1, 2]}) {
            name
            ...UserFields
            friends(first: $n) @include(if: true) {
              edges {
                node {
                  id
                }
              }
            }
            ... on Admin {
              level
            }
          }
        }
        """)
    }

    @Test func collapsesWhitespaceAndSeparatesDefinitions() {
        let q = "  {\n\n   a    b: c\n}fragment F on T{x}"
        #expect(GraphQLFormatter.format(q) == "{\n  a\n  b: c\n}\n\nfragment F on T {\n  x\n}")
    }

    @Test func keepsStringsAndComments() {
        let q = #"{ a(s: "  {  spaced }  ") # note { here"# + "\n" + #" b(t: """ block { """) }"#
        #expect(GraphQLFormatter.format(q) == """
        {
          a(s: "  {  spaced }  ") # note { here
          b(t: \""" block { \""")
        }
        """)
    }

    @Test func survivesUnbalancedInput() {
        #expect(GraphQLFormatter.format("}} { a ") == "}\n\n}\n\n{\n  a")
        #expect(GraphQLFormatter.format("a(b: (c") == "a(b: (c")
        #expect(GraphQLFormatter.format("") == "")
        let junk = "{ a(%%%) ¿ \"\"\"x"
        let formatted = GraphQLFormatter.format(junk)
        #expect(formatted.filter { !$0.isWhitespace } == junk.filter { !$0.isWhitespace })
    }
}

@Suite struct GraphQLRequestTests {
    @Test func parsesPostBodyKeepingVariableOrder() {
        let body = Data(#"{"operationName":"Q","query":"query Q { a }","variables":{"z":1,"a":{"b":true}}}"#.utf8)
        let requests = GraphQLRequest.parse(method: "POST", url: "https://a.test/gql", body: body)
        #expect(requests.count == 1)
        #expect(requests[0].operationName == "Q")
        #expect(requests[0].query == "query Q { a }")
        #expect(requests[0].variables?.serialized() == #"{"z":1,"a":{"b":true}}"#)
    }

    @Test func parsesBatchAndStringVariables() {
        let body = Data(#"[{"query":"{ a }","variables":null},{"query":"{ b }","variables":"{\"x\":2}"}]"#.utf8)
        let requests = GraphQLRequest.parse(method: "POST", url: "https://a.test/gql", body: body)
        #expect(requests.map(\.query) == ["{ a }", "{ b }"])
        #expect(requests[0].variables == nil)
        #expect(requests[1].variables?.serialized() == #"{"x":2}"#)
        #expect(GraphQLRequest.parse(method: "POST", url: "", body: Data(#"[{"query":"{ a }"},{}]"#.utf8)).isEmpty)
    }

    @Test func parsesGet() {
        let url = "https://a.test/gql?query=%7B%20a%20%7D&operationName=&variables=%7B%22id%22%3A1%7D"
        let requests = GraphQLRequest.parse(method: "GET", url: url, body: Data())
        #expect(requests == [GraphQLRequest(operationName: nil, query: "{ a }", variables: .object([JSONMember("id", .number("1"))]))])
        #expect(GraphQLRequest.parse(method: "GET", url: "https://a.test/", body: Data()).isEmpty)
    }
}
