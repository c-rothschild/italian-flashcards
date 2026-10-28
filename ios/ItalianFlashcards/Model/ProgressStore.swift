import Foundation
import Observation
import Security

enum StudyStatus: String, Codable, Sendable {
    case new, learning, mastered
}

/// Learn progress for one card. Same format as the website's data/progress.json.
struct StudyRecord: Codable, Equatable, Sendable {
    var status: StudyStatus
    var misses: Int
    var firstTry: Bool?
    var updated: Double // milliseconds since 1970; the newer record wins when merging

    static func now() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }
}

/// progress.json: {"version": 1, "terms": {"<term>\u0000<definition>": record}}.
/// Records that don't decode are skipped rather than failing the whole file.
struct ProgressFile: Codable {
    var version = 1
    var terms: [String: StudyRecord]

    init(terms: [String: StudyRecord]) { self.terms = terms }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        let raw = (try? c.decode([String: Lossy].self, forKey: .terms)) ?? [:]
        terms = raw.compactMapValues { $0.record.flatMap { $0.misses >= 0 ? $0 : nil } }
    }

    private struct Lossy: Decodable {
        let record: StudyRecord?
        init(from decoder: Decoder) throws { record = try? StudyRecord(from: decoder) }
    }

    /// Copies records from `other` that are newer than ours. Returns true if anything changed.
    @discardableResult
    static func merge(_ other: [String: StudyRecord], into mine: inout [String: StudyRecord]) -> Bool {
        var changed = false
        for (key, theirs) in other where theirs.updated > (mine[key]?.updated ?? -.infinity) {
            mine[key] = theirs
            changed = true
        }
        return changed
    }
}

/// The GitHub token used to save progress (Keychain, this device only).
struct TokenStore {
    var service = "ItalianFlashcards.github"

    func load() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) {
        delete()
        var query = base
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    func delete() { SecItemDelete(base as CFDictionary) }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "token"]
    }
}

/// Learn progress, kept on the device and synced with the website through progress.json on
/// the repo's "progress" branch. Anyone can read it (the repo is public); saving this
/// phone's progress back needs a GitHub token with write access to the repo.
@MainActor
@Observable
final class ProgressStore {
    static let branch = "progress"
    static let file = "progress.json"

    private(set) var records: [String: StudyRecord] = [:]
    /// Bumps when progress from the website arrives, so a running Learn session can catch up.
    private(set) var remoteRevision = 0
    private(set) var isSyncing = false
    private(set) var lastSynced: Date?
    private(set) var errorMessage: String?
    private(set) var hasToken: Bool
    private(set) var hasUnsavedChanges = false

    @ObservationIgnored let syncEnabled: Bool
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let tokens: TokenStore
    @ObservationIgnored private var remote: [String: StudyRecord]? // GitHub's copy as of the last fetch
    @ObservationIgnored private var sha: String?
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var syncAgain = false

    init(session: URLSession? = nil, directory: URL? = nil, tokens: TokenStore = TokenStore(), syncEnabled: Bool = true) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = dir.appending(path: "progress.json")
        self.tokens = tokens
        self.syncEnabled = syncEnabled
        hasToken = syncEnabled && tokens.load() != nil
        if let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(ProgressFile.self, from: data) {
            records = file.terms
        }
    }

    var masteredCount: Int { records.values.filter { $0.status == .mastered }.count }

    // MARK: local changes

    func save(_ key: String, status: StudyStatus, misses: Int, firstTry: Bool?) {
        records[key] = StudyRecord(status: status, misses: misses, firstTry: firstTry, updated: StudyRecord.now())
        changed()
    }

    /// Forgets the progress on these cards (Start over / Learn again).
    func reset(_ keys: [String]) {
        let now = StudyRecord.now()
        var any = false
        for key in keys where (records[key]?.status ?? .new) != .new {
            records[key] = StudyRecord(status: .new, misses: 0, firstTry: nil, updated: now)
            any = true
        }
        if any { changed() }
    }

    private func changed() {
        persist()
        hasUnsavedChanges = hasToken
        if hasToken { schedulePush() }
    }

    private func schedulePush() {
        if isSyncing { syncAgain = true; return } // don't cancel a request in flight
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .seconds(3)) // a burst of answers becomes one save
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(ProgressFile(terms: records)).write(to: fileURL, options: .atomic)
    }

    // MARK: token

    /// Checks the token can see the repo, stores it in the Keychain and syncs.
    func connect(token raw: String) async -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return "Paste a token first." }
        var request = apiRequest("", token: token)
        request.httpMethod = "GET"
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
            return "Couldn't reach GitHub. Check your connection and try again."
        }
        guard http.statusCode == 200 else {
            return http.statusCode == 401 ? "GitHub didn't accept that token." : "That token can't see \(CloudConfig.repo) (GitHub said \(http.statusCode))."
        }
        tokens.save(token)
        hasToken = true
        await sync()
        return errorMessage
    }

    func disconnect() {
        tokens.delete()
        hasToken = false
        hasUnsavedChanges = false
        errorMessage = nil
    }

    // MARK: GitHub

    /// Pulls the website's progress and, when signed in, saves this phone's newer progress.
    func sync() async {
        guard syncEnabled else { return }
        guard !isSyncing else { syncAgain = true; return }
        isSyncing = true
        await syncOnce()
        isSyncing = false
        if syncAgain {
            syncAgain = false
            if hasUnsavedChanges { schedulePush() }
        }
    }

    private func syncOnce() async {
        do {
            for _ in 0..<4 {
                let theirs = try await fetch()
                if ProgressFile.merge(theirs, into: &records) {
                    remoteRevision += 1
                    persist()
                }
                let ahead = records.contains { key, mine in mine.updated > (theirs[key]?.updated ?? -.infinity) }
                hasUnsavedChanges = ahead && hasToken
                guard ahead, hasToken else { break }
                if try await push() { break }
                etag = nil // the website saved in between: fetch, merge and try again
            }
            lastSynced = Date()
            errorMessage = nil
        } catch let error as SyncError {
            errorMessage = error.message
        } catch {
            errorMessage = "Couldn't reach GitHub. Progress is saved on this iPhone and will sync later."
        }
    }

    private struct SyncError: Error { let message: String }

    private func apiRequest(_ path: String, token: String? = nil) -> URLRequest {
        let base = "https://api.github.com/repos/\(CloudConfig.owner)/\(CloudConfig.repo)"
        var request = URLRequest(url: URL(string: path.isEmpty ? base : "\(base)/\(path)")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("ItalianFlashcards-iOS", forHTTPHeaderField: "User-Agent")
        if let token = token ?? (hasToken ? tokens.load() : nil) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Int, Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http.statusCode, data, http)
    }

    private func fetch() async throws -> [String: StudyRecord] {
        var request = apiRequest("contents/\(Self.file)?ref=\(Self.branch)")
        if let etag, remote != nil { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (status, data, http) = try await send(request)
        switch status {
        case 304:
            return remote ?? [:]
        case 404: // nobody has saved progress yet
            sha = nil
            etag = nil
            remote = [:]
            return [:]
        case 200:
            struct Contents: Decodable { let sha: String; let content: String }
            let contents = try JSONDecoder().decode(Contents.self, from: data)
            guard let fileData = Data(base64Encoded: contents.content, options: .ignoreUnknownCharacters) else {
                throw URLError(.cannotParseResponse)
            }
            let file = try JSONDecoder().decode(ProgressFile.self, from: fileData)
            sha = contents.sha
            etag = http.value(forHTTPHeaderField: "ETag")
            remote = file.terms
            return file.terms
        case 401:
            throw SyncError(message: "GitHub no longer accepts the saved token. Connect GitHub again.")
        case 403, 429:
            throw SyncError(message: "GitHub is limiting requests right now. Progress will sync later.")
        default:
            throw SyncError(message: "GitHub said \(status) while loading progress.")
        }
    }

    /// Returns false if GitHub's copy changed since we fetched it.
    private func push() async throws -> Bool {
        let snapshot = records
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var body: [String: String] = [
            "message": "Update learn progress from iPhone (\(snapshot.values.filter { $0.status == .mastered }.count) mastered)",
            "branch": Self.branch,
            "content": try encoder.encode(ProgressFile(terms: snapshot)).base64EncodedString(),
        ]
        if let sha { body["sha"] = sha }
        var request = apiRequest("contents/\(Self.file)")
        request.httpMethod = "PUT"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        var (status, data, _) = try await send(request)
        if status == 404, sha == nil {
            try await createBranch()
            (status, data, _) = try await send(request)
        }
        switch status {
        case 200, 201:
            struct Saved: Decodable { struct Content: Decodable { let sha: String }; let content: Content }
            sha = try JSONDecoder().decode(Saved.self, from: data).content.sha
            remote = snapshot
            etag = nil
            hasUnsavedChanges = records != snapshot
            return true
        case 409, 422:
            return false
        case 401:
            throw SyncError(message: "GitHub no longer accepts the saved token. Connect GitHub again.")
        case 403, 404:
            throw SyncError(message: "The saved token can't write to \(CloudConfig.repo). Give it Contents: Read and write access.")
        default:
            throw SyncError(message: "GitHub said \(status) while saving progress.")
        }
    }

    private func createBranch() async throws {
        let (status, data, _) = try await send(apiRequest("git/ref/heads/\(CloudConfig.branch)"))
        guard status == 200 else { throw SyncError(message: "Couldn't set up progress syncing on GitHub (\(status)).") }
        struct Ref: Decodable { struct Object: Decodable { let sha: String }; let object: Object }
        let base = try JSONDecoder().decode(Ref.self, from: data).object.sha
        var request = apiRequest("git/refs")
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ref": "refs/heads/\(Self.branch)", "sha": base])
        let (created, _, _) = try await send(request)
        guard created == 201 || created == 422 else { // 422: it already exists
            throw SyncError(message: "Couldn't set up progress syncing on GitHub (\(created)).")
        }
    }
}
