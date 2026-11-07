@testable import Archive
import Foundation
import ProxyModel
import Testing

@Suite struct OpenAPITests {
    @Test func openAPI3YAMLBecomesRequests() throws {
        let yaml = """
        openapi: 3.0.3
        info: { title: Pets, version: "1.2" }
        servers:
          - url: https://{env}.pets.test/v1/
            variables: { env: { default: api } }
        paths:
          /pets/{petId}:
            parameters:
              - { name: petId, in: path, required: true, schema: { type: integer, example: 7 } }
            get:
              operationId: getPet
              tags: [pets]
              parameters:
                - { name: X-Trace, in: header, schema: { type: string } }
                - { name: verbose, in: query, required: true, schema: { type: boolean, default: true } }
                - { name: optional, in: query, schema: { type: string } }
          /pets:
            post:
              summary: Add a pet
              requestBody:
                content:
                  application/json:
                    schema: { $ref: '#/components/schemas/Pet' }
        components:
          schemas:
            Pet:
              type: object
              properties:
                name: { type: string, example: Rex }
                age: { type: integer }
                tags: { type: array, items: { type: string } }
                owner: { $ref: '#/components/schemas/Owner' }
            Owner:
              type: object
              properties: { email: { type: string, format: email } }
        """
        let c = try OpenAPIImporter.importDocument(Data(yaml.utf8), fileName: "pets.yaml")
        #expect(c.title == "Pets" && c.version == "1.2" && c.baseURL == "https://api.pets.test/v1")
        let get = try #require(c.requests.first { $0.name == "getPet" })
        #expect(get.tag == "pets")
        #expect(get.request.method == "GET")
        #expect(get.request.url == "https://api.pets.test/v1/pets/7?verbose=true")
        #expect(get.request.headers == [HeaderField(name: "X-Trace", value: "")])
        let post = try #require(c.requests.first { $0.name == "POST /pets" })
        #expect(post.summary == "Add a pet")
        #expect(post.request.headers == [HeaderField(name: "Content-Type", value: "application/json")])
        let body = try JSONSerialization.jsonObject(with: try #require(post.request.body)) as! [String: Any]
        #expect(body["name"] as? String == "Rex")
        #expect(body["age"] as? Int == 0)
        #expect(body["tags"] as? [String] == ["string"])
        #expect((body["owner"] as? [String: String])?["email"] == "user@example.com")
    }

    @Test func requestBodyExampleWins() throws {
        let json = """
        {"openapi":"3.1.0","info":{"title":"T","version":"1"},"servers":[{"url":"https://t.test"}],
         "paths":{"/x":{"put":{"requestBody":{"content":{"application/json":{"example":{"a":1},"schema":{"type":"object"}}}}}}}}
        """
        let c = try OpenAPIImporter.importDocument(Data(json.utf8), fileName: "t.json")
        let body = try JSONSerialization.jsonObject(with: try #require(c.requests[0].request.body)) as! [String: Int]
        #expect(body == ["a": 1])
        #expect(c.requests[0].request.url == "https://t.test/x")
    }

    @Test func swagger2() throws {
        let json = """
        {"swagger":"2.0","info":{"title":"Old","version":"0.1"},"host":"old.test","basePath":"/api","schemes":["http"],
         "paths":{"/users":{"post":{"operationId":"createUser","consumes":["application/json"],
           "parameters":[{"name":"body","in":"body","schema":{"$ref":"#/definitions/User"}}]}}},
         "definitions":{"User":{"type":"object","properties":{"id":{"type":"string","format":"uuid"}}}}}
        """
        let c = try OpenAPIImporter.importDocument(Data(json.utf8), fileName: "old.json")
        #expect(c.baseURL == "http://old.test/api")
        let r = c.requests[0]
        #expect(r.request.url == "http://old.test/api/users")
        let body = try JSONSerialization.jsonObject(with: try #require(r.request.body)) as! [String: String]
        #expect(body == ["id": "00000000-0000-0000-0000-000000000000"])
    }

    @Test func recursiveSchemasStop() throws {
        let json = """
        {"openapi":"3.0.0","info":{"title":"R","version":"1"},"paths":{"/n":{"post":{"requestBody":{"content":{"application/json":
         {"schema":{"$ref":"#/components/schemas/Node"}}}}}}},
         "components":{"schemas":{"Node":{"type":"object","properties":{"next":{"$ref":"#/components/schemas/Node"}}}}}}
        """
        let c = try OpenAPIImporter.importDocument(Data(json.utf8), fileName: "r.json")
        #expect(c.requests[0].request.body != nil)
    }

    @Test func rejectsOtherDocuments() {
        #expect(throws: ArchiveError.self) { try OpenAPIImporter.importDocument(Data("{\"a\":1}".utf8), fileName: "a") }
        #expect(throws: ArchiveError.self) { try OpenAPIImporter.importDocument(Data(": : :".utf8), fileName: "a") }
    }
}
