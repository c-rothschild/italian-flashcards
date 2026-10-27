import XCTest
@testable import ItalianFlashcards

/// Serves canned responses so the cloud download can be tested without the network.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], String)?)?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let (status, headers, body) = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class TermRepositoryTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private var session: URLSession!

    private let cloudCSV = "term,definition,category\ncane,dog,Animals\ngatto,cat,Animals\nfinestra,window,Casa\n"

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defaults = UserDefaults(suiteName: UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
        StubURLProtocol.requests = []
        StubURLProtocol.handler = nil
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeRepository() -> TermRepository {
        TermRepository(session: session, cacheDirectory: dir, defaults: defaults, bundle: Bundle(for: TermRepository.self))
    }

    func testStartsWithBundledCardsThenDownloadsAndSaves() async {
        let repo = makeRepository()
        XCTAssertEqual(repo.source, .bundled)
        XCTAssertGreaterThan(repo.terms.count, 100)

        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.host, "api.github.com")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/vnd.github.raw+json")
            return (200, ["ETag": "\"v1\""], self.cloudCSV)
        }
        await repo.refresh()
        XCTAssertEqual(repo.source, .cloud)
        XCTAssertEqual(repo.terms.map(\.term), ["cane", "gatto", "finestra"])
        XCTAssertEqual(repo.categories, ["Animals", "Casa"])
        XCTAssertNil(repo.errorMessage)
        XCTAssertNotNil(repo.lastUpdated)

        // A fresh launch uses the saved copy, and asks GitHub only for changes.
        let relaunched = makeRepository()
        XCTAssertEqual(relaunched.source, .saved)
        XCTAssertEqual(relaunched.terms.count, 3)
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
            return (304, [:], "")
        }
        await relaunched.refresh()
        XCTAssertEqual(relaunched.terms.count, 3)
        XCTAssertNil(relaunched.errorMessage)
    }

    func testFallsBackToRawFileWhenApiFails() async {
        let repo = makeRepository()
        StubURLProtocol.handler = { req in
            req.url?.host == "api.github.com" ? (403, [:], "rate limited") : (200, [:], self.cloudCSV)
        }
        await repo.refresh()
        XCTAssertEqual(repo.terms.count, 3)
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.host, "raw.githubusercontent.com")
    }

    func testOfflineKeepsCurrentCardsAndShowsMessage() async {
        let repo = makeRepository()
        let before = repo.terms
        StubURLProtocol.handler = nil // every request fails
        await repo.refresh()
        XCTAssertEqual(repo.terms, before)
        XCTAssertNotNil(repo.errorMessage)
    }

    func testDescribeChange() {
        let a = Term(term: "cane", definition: "dog", category: "Animals")
        let b = Term(term: "gatto", definition: "cat", category: "Animals")
        let c = Term(term: "pane", definition: "bread", category: "Food")
        XCTAssertNil(TermRepository.describeChange(from: [a, b], to: [a, b]))
        XCTAssertEqual(TermRepository.describeChange(from: [a, b], to: [a, c]), "Updated: 1 new card, 1 removed")
        let moved = Term(term: "cane", definition: "dog", category: "Pets")
        XCTAssertEqual(TermRepository.describeChange(from: [a], to: [moved]), "Updated: 1 moved")
    }
}
