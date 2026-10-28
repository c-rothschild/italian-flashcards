import XCTest
@testable import ItalianFlashcards

@MainActor
final class ProgressStoreTests: XCTestCase {
    private var dir: URL!
    private var session: URLSession!
    private var tokens: TokenStore!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
        tokens = TokenStore(service: "ItalianFlashcardsTests.\(UUID().uuidString)")
        StubURLProtocol.requests = []
    }

    override func tearDown() async throws {
        tokens.delete()
        StubURLProtocol.handler = nil
    }

    private func record(_ status: StudyStatus, _ updated: Double, misses: Int = 0) -> StudyRecord {
        StudyRecord(status: status, misses: misses, firstTry: status == .mastered, updated: updated)
    }

    private func contentsJSON(_ terms: [String: StudyRecord], sha: String) throws -> String {
        let file = try JSONEncoder().encode(ProgressFile(terms: terms)).base64EncodedString()
        return #"{"sha":"\#(sha)","content":"\#(file)"}"#
    }

    private func body(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func savedTerms(_ request: URLRequest) throws -> [String: StudyRecord] {
        let content = try XCTUnwrap(body(of: request)["content"] as? String)
        return try JSONDecoder().decode(ProgressFile.self, from: XCTUnwrap(Data(base64Encoded: content))).terms
    }

    func testNewerRecordWinsAndBadRecordsAreSkipped() throws {
        var mine = ["a": record(.learning, 100), "b": record(.mastered, 300)]
        let changed = ProgressFile.merge(["a": record(.mastered, 200), "b": record(.new, 250), "c": record(.new, 1)], into: &mine)
        XCTAssertTrue(changed)
        XCTAssertEqual(mine["a"]?.status, .mastered)
        XCTAssertEqual(mine["b"]?.status, .mastered, "older change loses")
        XCTAssertEqual(mine.count, 3)

        let json = #"{"version":1,"terms":{"ok\u0000x":{"status":"learning","misses":2,"firstTry":null,"updated":5},"bad":{"status":"??","updated":1},"alsoBad":{"status":"new"}}}"#
        let file = try JSONDecoder().decode(ProgressFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.terms.keys.sorted(), ["ok\u{0}x"])
        XCTAssertNil(file.terms["ok\u{0}x"]?.firstTry)
    }

    func testPullsWebsiteProgressWithoutAToken() async throws {
        let website = ["cane\u{0}dog": record(.mastered, 1000)]
        let json = try contentsJSON(website, sha: "s1")
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "GET")
            XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
            XCTAssertTrue(req.url!.absoluteString.hasSuffix("contents/progress.json?ref=progress"))
            return (200, ["ETag": "\"e1\""], json)
        }
        let store = ProgressStore(session: session, directory: dir, tokens: tokens)
        store.save("gatto\u{0}cat", status: .learning, misses: 1, firstTry: false)
        await store.sync()
        XCTAssertEqual(store.records["cane\u{0}dog"]?.status, .mastered)
        XCTAssertEqual(store.remoteRevision, 1)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.hasUnsavedChanges, "can't save without a token")
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "no attempt to save")

        // Saved on the device.
        let reopened = ProgressStore(session: session, directory: dir, tokens: tokens)
        XCTAssertEqual(reopened.records.count, 2)
    }

    func testSavesWithTokenAndRetriesWhenTheWebsiteSavedFirst() async throws {
        tokens.save("test-token")
        var remote = ["cane\u{0}dog": record(.learning, 1000, misses: 1)]
        var sha = 1
        var puts = 0
        StubURLProtocol.handler = { [self] req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            if req.httpMethod == "GET" {
                return (200, [:], try! contentsJSON(remote, sha: "s\(sha)"))
            }
            puts += 1
            if puts == 1 {
                // The website saves in between.
                remote["finestra\u{0}window"] = record(.mastered, 4000)
                sha += 1
                return (409, [:], #"{"message":"conflict"}"#)
            }
            XCTAssertEqual(body(of: req)["sha"] as? String, "s\(sha)")
            XCTAssertEqual(body(of: req)["branch"] as? String, "progress")
            remote = try! savedTerms(req)
            sha += 1
            return (200, [:], #"{"content":{"sha":"s\#(sha)"}}"#)
        }
        let store = ProgressStore(session: session, directory: dir, tokens: tokens)
        XCTAssertTrue(store.hasToken)
        store.save("cane\u{0}dog", status: .mastered, misses: 1, firstTry: false) // newer than the website's
        await store.sync()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(puts, 2)
        XCTAssertEqual(remote["cane\u{0}dog"]?.status, .mastered)
        XCTAssertEqual(remote["finestra\u{0}window"]?.status, .mastered, "kept the website's progress")
        XCTAssertEqual(store.records, remote)
        XCTAssertFalse(store.hasUnsavedChanges)

        // Nothing new: no save.
        await store.sync()
        XCTAssertEqual(puts, 2)
    }

    func testResetOnlyTouchesStartedTerms() {
        StubURLProtocol.handler = nil
        let store = ProgressStore(session: session, directory: dir, tokens: tokens, syncEnabled: false)
        store.save("a", status: .mastered, misses: 0, firstTry: true)
        store.reset(["a", "b"])
        XCTAssertEqual(store.records["a"]?.status, .new)
        XCTAssertNil(store.records["b"])
    }
}
