import Foundation
import Observation

/// Where the website pushes the flashcards (see server.py's GitHub sync).
enum CloudConfig {
    static let owner = "c-rothschild"
    static let repo = "italian-flashcards"
    static let branch = "main"
    static let path = "data/terms.csv"

    /// GitHub's API serves the file straight from the repo (no CDN delay).
    static var apiURL: URL { URL(string: "https://api.github.com/repos/\(owner)/\(repo)/contents/\(path)?ref=\(branch)")! }
    /// Fallback if the API is unavailable or rate-limited (60 requests/hour without login).
    static var rawURL: URL { URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(path)")! }
}

/// Holds the flashcards: the last copy downloaded from GitHub (or the copy bundled
/// with the app on first launch), refreshed from the cloud on demand.
@MainActor
@Observable
final class TermRepository {
    enum Source { case bundled, saved, cloud }

    private(set) var terms: [Term] = []
    private(set) var categories: [String] = [] // alphabetical; "" (uncategorized) last
    private(set) var source: Source = .bundled
    private(set) var lastUpdated: Date?        // last successful check with GitHub
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    private(set) var lastChange: String?       // e.g. "5 new cards" after a refresh
    private var counts: [String: Int] = [:]

    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private var lastAttempt: Date?

    private static let etagKey = "cloud.etag"
    private static let updatedKey = "cloud.lastUpdated"

    init(session: URLSession? = nil, cacheDirectory: URL? = nil, defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
        self.defaults = defaults
        let dir = cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        cacheURL = dir.appending(path: "terms.csv")
        lastUpdated = defaults.object(forKey: Self.updatedKey) as? Date

        if let text = try? String(contentsOf: cacheURL, encoding: .utf8), case let saved = TermsCSV.parse(text), !saved.isEmpty {
            apply(saved)
            source = .saved
        } else if let url = bundle.url(forResource: "terms", withExtension: "csv"),
                  let text = try? String(contentsOf: url, encoding: .utf8) {
            apply(TermsCSV.parse(text))
            source = .bundled
        }
    }

    func count(of category: String) -> Int { counts[category, default: 0] }

    /// Refresh unless we checked in the last minute (used when the app comes to the foreground).
    func refreshIfStale() async {
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < 60 { return }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        lastAttempt = Date()
        do {
            if let text = try await download() {
                let fresh = TermsCSV.parse(text)
                guard !fresh.isEmpty else { throw URLError(.cannotParseResponse) }
                lastChange = Self.describeChange(from: terms, to: fresh)
                apply(fresh)
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: cacheURL, atomically: true, encoding: .utf8)
                source = .cloud
            } else {
                lastChange = nil // not modified since last download
            }
            lastUpdated = Date()
            defaults.set(lastUpdated, forKey: Self.updatedKey)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't reach GitHub, so you're seeing the cards saved on this device."
        }
    }

    /// Returns the CSV text, or nil if it hasn't changed since the last download.
    private func download() async throws -> String? {
        var request = URLRequest(url: CloudConfig.apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        request.setValue("ItalianFlashcards-iOS", forHTTPHeaderField: "User-Agent")
        let haveSavedCopy = FileManager.default.fileExists(atPath: cacheURL.path)
        if haveSavedCopy, let etag = defaults.string(forKey: Self.etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse {
            if http.statusCode == 304, haveSavedCopy { return nil }
            if http.statusCode == 200, let text = String(data: data, encoding: .utf8) {
                defaults.set(http.value(forHTTPHeaderField: "ETag"), forKey: Self.etagKey)
                return text
            }
        }

        // Fallback: the raw file (cache-busted, since raw.githubusercontent.com caches for ~5 minutes).
        var components = URLComponents(url: CloudConfig.rawURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
        let raw = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (data, response) = try await session.data(for: raw)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        defaults.removeObject(forKey: Self.etagKey)
        return text
    }

    private func apply(_ newTerms: [Term]) {
        terms = newTerms
        var counts: [String: Int] = [:]
        for t in newTerms { counts[t.category, default: 0] += 1 }
        self.counts = counts
        let named = counts.keys.filter { !$0.isEmpty }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        categories = named + (counts[""] != nil ? [""] : [])
    }

    static func describeChange(from old: [Term], to new: [Term]) -> String? {
        let oldIDs = Set(old.map(\.id)), newIDs = Set(new.map(\.id))
        let added = newIDs.subtracting(oldIDs).count
        let removed = oldIDs.subtracting(newIDs).count
        let newByID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recategorized = old.filter { t in newByID[t.id].map { $0.category != t.category } ?? false }.count
        var parts: [String] = []
        if added > 0 { parts.append("\(added) new card\(added == 1 ? "" : "s")") }
        if removed > 0 { parts.append("\(removed) removed") }
        if recategorized > 0 { parts.append("\(recategorized) moved") }
        return parts.isEmpty ? nil : "Updated: " + parts.joined(separator: ", ")
    }
}

/// Which categories are being studied. Stores the *unchecked* ones, so categories
/// added later on the website start out selected (same as the website).
@MainActor
@Observable
final class CategorySelection {
    private(set) var deselected: Set<String>
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "study.deselected"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        deselected = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isSelected(_ category: String) -> Bool { !deselected.contains(category) }

    func set(_ category: String, selected: Bool) {
        if selected { deselected.remove(category) } else { deselected.insert(category) }
        save()
    }

    func selectAll() { deselected.removeAll(); save() }
    func selectNone(_ categories: [String]) { deselected = Set(categories); save() }

    func pool(from terms: [Term]) -> [Term] { terms.filter { isSelected($0.category) } }

    private func save() { defaults.set(Array(deselected).sorted(), forKey: Self.key) }
}
