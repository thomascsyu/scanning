import XCTest
@testable import StatementCore

private final class MockDeepSeekProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class DeepSeekTests: XCTestCase {
    let categories = ["Uncategorized", "Software", "Office supplies"]
    func client() -> DeepSeekClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockDeepSeekProtocol.self]
        return DeepSeekClient(session: URLSession(configuration: config))
    }
    override func tearDown() { MockDeepSeekProtocol.handler = nil }
    func completion(category: String = "Software", type: String = "Purchase", finish: String = "stop", explanation: String = "Software merchant.") throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: ["category":category, "transaction_type":type, "explanation":explanation])
        return try JSONSerialization.data(withJSONObject: ["choices":[["finish_reason":finish,"message":["content":String(data:json,encoding:.utf8)!]]]])
    }
    func testRequestUsesFlashAndMinimumTransactionData() throws {
        let request = try DeepSeekClient.suggestionRequest(description: "示例軟件 invoice 0001", direction: .outgoing, categories: categories, apiKey: "synthetic-test-key")
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String:Any])
        XCTAssertEqual(body["model"] as? String, "deepseek-flash")
        XCTAssertEqual((body["thinking"] as? [String:String])?["type"], "disabled")
        XCTAssertEqual((body["response_format"] as? [String:String])?["type"], "json_object")
        let messages = try XCTUnwrap(body["messages"] as? [[String:String]])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as? [String:Any])
        XCTAssertEqual(Set(payload.keys), Set(["description","direction","currency","allowed_categories","allowed_transaction_types"]))
        XCTAssertEqual(payload["description"] as? String,"示例軟件 invoice 0001")
        XCTAssertFalse((payload["allowed_transaction_types"] as? [String] ?? []).contains("Transfer"))
        XCTAssertFalse(String(data: request.httpBody!,encoding:.utf8)!.contains("synthetic-test-key"))
    }
    func testInvalidKeyAndInputRejectedBeforeRequest() throws {
        for invalid in ["", "Bearer sk-test", "abc\r\nInjected: true", "\"sk-test\""] {
            XCTAssertThrowsError(try DeepSeekClient.suggestionRequest(description: "Test", direction: .outgoing, categories: categories, apiKey: invalid))
        }
        XCTAssertThrowsError(try DeepSeekClient.suggestionRequest(description: "", direction: .outgoing, categories: categories, apiKey: "test"))
        XCTAssertThrowsError(try DeepSeekClient.suggestionRequest(description: String(repeating:"x",count:8001), direction: .outgoing, categories: categories, apiKey: "test"))
        XCTAssertThrowsError(try DeepSeekClient.suggestionRequest(description: "Test", direction: .any, categories: categories, apiKey: "test"))
        XCTAssertEqual(try DeepSeekClient.validatedKey("  synthetic-test\n"), "synthetic-test")
    }
    func testSuggestionValidationRejectsInventedCategoriesTransfersAndTruncation() throws {
        let accepted = try DeepSeekClient.decodeSuggestion(completion(), categories: categories)
        XCTAssertEqual(accepted.category,"Software"); XCTAssertEqual(accepted.transactionType,.purchase)
        for data in [try completion(category:"Invented"), try completion(type:"Transfer"), try completion(finish:"length"), try completion(explanation:""), Data("invalid json".utf8), Data(repeating:0,count:262145)] {
            XCTAssertThrowsError(try DeepSeekClient.decodeSuggestion(data,categories:categories))
        }
    }
    func testConnectionOnlyListsModels() async throws {
        MockDeepSeekProtocol.handler = { request in
            XCTAssertEqual(request.url?.path,"/models"); XCTAssertEqual(request.httpMethod,"GET"); XCTAssertNil(request.httpBody)
            return (200,Data(#"{"data":[{"id":"deepseek-flash"}]}"#.utf8))
        }
        try await client().checkConnection(apiKey:"test-only")
    }
    func testUnavailableModelDoesNotSubstituteAnotherModel() async throws {
        MockDeepSeekProtocol.handler = { _ in (200,Data(#"{"data":[{"id":"deepseek-v4-pro"}]}"#.utf8)) }
        do { try await client().checkConnection(apiKey:"test-only"); XCTFail("Expected model rejection") }
        catch DeepSeekError.modelUnavailable { }
    }
    func testHTTPFailuresDoNotExposeProviderResponseBody() async throws {
        for (status, expected) in [(401,"API key"),(402,"balance"),(429,"rate-limiting"),(503,"unavailable"),(400,"HTTP 400"),(302,"HTTP 302")] {
            MockDeepSeekProtocol.handler = { _ in (status,Data("PRIVATE PROVIDER RESPONSE test-only".utf8)) }
            do { try await client().checkConnection(apiKey:"test-only"); XCTFail("Expected HTTP rejection") }
            catch { XCTAssertTrue(error.localizedDescription.contains(expected)); XCTAssertFalse(error.localizedDescription.contains("PRIVATE")); XCTAssertFalse(error.localizedDescription.contains("test-only")) }
        }
    }
    func testSuggestionRequestAndResponseEndToEndWithoutNetwork() async throws {
        let data = try completion()
        MockDeepSeekProtocol.handler = { request in XCTAssertEqual(request.url?.host,"api.deepseek.com"); return (200,data) }
        let result = try await client().suggest(description:"EXAMPLE SOFTWARE",direction:.outgoing,categories:categories,apiKey:"test-only")
        XCTAssertEqual(result.category,"Software")
    }
    func testCancellationIsNotReportedAsNetworkFailure() async throws {
        MockDeepSeekProtocol.handler = { _ in throw URLError(.cancelled) }
        do { try await client().checkConnection(apiKey:"test-only"); XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
    func testRedirectsAreBlocked() {
        let blocker = DeepSeekRedirectBlocker()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string:"https://other.example/")!)
        let response = HTTPURLResponse(url:URL(string:DeepSeekClient.baseURL)!,statusCode:302,httpVersion:nil,headerFields:nil)!
        blocker.urlSession(session,task:session.dataTask(with:request),willPerformHTTPRedirection:response,newRequest:request) { redirected in XCTAssertNil(redirected) }
    }
}
