import Foundation
import Stoic
import StoicJSON
import StoicHTTP
import Testing

@Suite("HTTP requests")
struct RequestTests {
    @Test func methodsKnowWhetherTheyAreSafeAndIdempotent() {
        for method in [HTTPMethod.get, .head, .options, .trace] {
            #expect(method.isSafe && method.isIdempotent, "\(method)")
        }
        for method in [HTTPMethod.put, .delete] {
            #expect(!method.isSafe && method.isIdempotent, "\(method)")
        }
        for method in [HTTPMethod.post, .patch, "PROPFIND"] {
            #expect(!method.isSafe && !method.isIdempotent, "\(method)")
        }
        #expect(HTTPMethod(rawValue: "get") == .get)
    }

    @Test func headerNamesAreCaseInsensitiveAndSettingReplaces() {
        var headers: HTTPHeaders = ["Accept": "application/json"]
        #expect(headers["accept"] == "application/json")
        headers["ACCEPT"] = "text/plain"
        #expect(headers.values(for: "Accept") == ["text/plain"])
        headers["accept"] = nil
        #expect(headers.isEmpty)
        headers.add("Via", "a")
        headers.add("via", "b")
        #expect(headers.values(for: "VIA") == ["a", "b"])
    }

    @Test func mergingReplacesByNameCaseInsensitively() {
        let merged = HTTPHeaders([HTTPHeaders.Field(name: "Accept", value: "a"), HTTPHeaders.Field(name: "X-One", value: "1")]).merging(["accept": "b"])
        #expect(merged["Accept"] == "b")
        #expect(merged["X-One"] == "1")
        #expect(merged.fields.count == 2)
    }

    @Test func credentialsNeverAppearInADescription() {
        let headers: HTTPHeaders = [
            "Authorization": "Bearer s3cret", "cookie": "sid=s3cret", "Set-Cookie": "sid=s3cret",
            "Proxy-Authorization": "Basic s3cret", "Accept": "text/plain",
        ]
        for text in [headers.description, headers.debugDescription, "\(headers)"] {
            #expect(!text.contains("s3cret"))
            #expect(text.contains("Accept: text/plain"))
        }
        #expect(headers.removingSensitive().fields.map(\.name) == ["Accept"])
        let request = HTTPRequest(method: .get, target: .path("/x"), headers: headers)
        #expect(!"\(request)".contains("s3cret"))
    }

    @Test func aRequestDescriptionHasNoQueryAndNoBody() {
        let request = HTTPRequest.get("/search", query: [URLQueryItem(name: "q", value: "private words")])
        #expect("\(request)" == "GET /search")
    }

    @Test func theQueryIsAppendedToTheURLsOwn() throws {
        let request = HTTPRequest.get(
            try #require(URL(string: "https://example.com/a?x=1")), query: [URLQueryItem(name: "y", value: "a b")])
        let url = try #require(request.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items == [URLQueryItem(name: "x", value: "1"), URLQueryItem(name: "y", value: "a b")])
        #expect(HTTPRequest.get("/relative").url == nil)
    }

    @Test func aJSONBodyIsBytesWithAContentType() throws {
        let request = HTTPRequest.post("/orders", json: ["id": 7])
        #expect(request.method == .post)
        #expect(request.headers["content-type"] == "application/json")
        #expect(String(decoding: try #require(request.body), as: UTF8.self) == #"{"id":7}"#)
    }

    @Test func onlyIdempotentOrKeyedRequestsAreSafeToRepeat() {
        let key = IdempotencyKey(rawValue: "k1")
        #expect(HTTPRequest.get("/a").isSafeToRepeat)
        #expect(HTTPRequest.delete("/a").isSafeToRepeat)
        #expect(!HTTPRequest.post("/a", json: .null).isSafeToRepeat)
        #expect(HTTPRequest.post("/a", json: .null).keyed(key).isSafeToRepeat)
        #expect(HTTPRequest.patch("/a", json: .null, headers: ["Idempotency-Key": "x"]).isSafeToRepeat)
    }
}
