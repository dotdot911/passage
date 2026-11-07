import Storage
import Testing

@Suite struct EndpointKeyTests {
    @Test func dropsQuery() {
        #expect(EndpointKey.of("https://httpbin.org/get?user=dev&page=2") == "/get")
    }

    @Test func foldsNumericSegments() {
        #expect(EndpointKey.of("https://httpbin.org/status/500") == "/status/{id}")
        #expect(EndpointKey.of("https://api.example.com/users/42/posts/7") == "/users/{id}/posts/{id}")
    }

    @Test func foldsUUIDAndLongHex() {
        #expect(EndpointKey.of("https://a.io/items/3F2504E0-4F89-11D3-9A0C-0305E82C3301") == "/items/{id}")
        #expect(EndpointKey.of("https://a.io/blob/0123456789abcdef01") == "/blob/{id}")
    }

    @Test func keepsWordsAndShortHex() {
        #expect(EndpointKey.of("https://a.io/v2/cafe/deadbeef") == "/v2/cafe/deadbeef")
    }

    @Test func rootAndEmpty() {
        #expect(EndpointKey.of("https://a.io") == "/")
        #expect(EndpointKey.of("https://a.io/") == "/")
    }

    @Test func keepsTrailingSlash() {
        #expect(EndpointKey.of("https://a.io/users/12/") == "/users/{id}/")
    }
}
