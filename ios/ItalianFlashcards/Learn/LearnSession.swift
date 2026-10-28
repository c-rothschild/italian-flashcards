import Foundation
import Observation

enum AnswerMode: String, CaseIterable, Identifiable {
    case term, definition, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .term: "Italian"
        case .definition: "English"
        case .both: "Both"
        }
    }
}

/// A Quizlet-style Learn session (same rules as the website): terms come in rounds of
/// 7; a correct answer masters a term; a missed term must be retyped and leads the next
/// round; "Override: I was right" counts a miss as correct. Ends when all are mastered.
/// Starts from saved progress (mastered terms are done, ones still being learned come
/// first) and reports every answer through `onRecord` so it can be saved and synced.
@MainActor
@Observable
final class LearnSession {
    enum Phase: Equatable { case asking, correct, wrong, summary, done }
    typealias Status = StudyStatus

    struct Item {
        var term: Term
        var status: Status = .new
        var misses = 0
        var firstTry: Bool? // nil until first answered
    }

    struct Round {
        var number: Int
        var keys: [String]
        var index = 0
        var results: [String: Bool] = [:]
    }

    struct Question {
        let id = UUID()
        let key: String
        let answerSide: CardSide
        let firstAttempt: Bool
        var given: String? // nil when the user chose "Don't know"
        var grade: Grade?
    }

    static let roundSize = 7

    private(set) var items: [String: Item] = [:]
    private(set) var order: [String] = []
    private(set) var queue: [String] = []
    private(set) var round: Round?
    private(set) var phase: Phase = .asking
    private(set) var question: Question?
    /// Skipped terms that haven't come back yet, most recent last.
    private(set) var skipped: [String] = []
    let missedOnly: Bool
    var answerMode: AnswerMode
    /// Called with a term's key whenever an answer changes its progress (not for "practice missed").
    @ObservationIgnored var onRecord: ((String, Item) -> Void)?

    init(terms: [Term], answerMode: AnswerMode, missedOnly: Bool = false, progress: [String: StudyRecord] = [:]) {
        self.answerMode = answerMode
        self.missedOnly = missedOnly
        for t in terms where items[t.id] == nil {
            var item = Item(term: t)
            if !missedOnly, let saved = progress[t.id] {
                item.status = saved.status
                item.misses = saved.misses
                item.firstTry = saved.firstTry
            }
            items[t.id] = item
            order.append(t.id)
        }
        let learning = order.filter { items[$0]?.status == .learning }
        let fresh = order.filter { items[$0]?.status == .new }
        queue = learning.shuffled() + fresh.shuffled()
        startRound()
    }

    private func record(_ key: String) {
        guard !missedOnly, let item = items[key] else { return }
        onRecord?(key, item)
    }

    var isEmpty: Bool { items.isEmpty }
    var total: Int { items.count }
    var masteredCount: Int { items.values.filter { $0.status == .mastered }.count }
    var learningCount: Int { items.values.filter { $0.status == .learning }.count }
    var newCount: Int { total - masteredCount - learningCount }
    var firstTryCount: Int { items.values.filter { $0.firstTry == true }.count }
    var currentItem: Item? { question.flatMap { items[$0.key] } }

    var expectedAnswer: String? {
        guard let q = question, let item = items[q.key] else { return nil }
        return q.answerSide.text(of: item.term)
    }

    var roundResults: [(item: Item, correct: Bool)] {
        guard let round else { return [] }
        return round.keys.compactMap { k in items[k].map { ($0, round.results[k] == true) } }
    }

    var mostMissed: [Item] {
        order.compactMap { items[$0] }.filter { $0.misses > 0 }.sorted { $0.misses > $1.misses }
    }

    // MARK: flow

    func startRound() {
        guard !queue.isEmpty else { phase = .done; return }
        let take = Array(queue.prefix(Self.roundSize))
        queue.removeFirst(take.count)
        round = Round(number: (round?.number ?? 0) + 1, keys: take)
        askCurrent()
    }

    /// (Re)asks the current term, picking the answer side from `answerMode`.
    func askCurrent() {
        guard let round, round.index < round.keys.count else { return }
        let key = round.keys[round.index]
        let side: CardSide = switch answerMode {
        case .term: .term
        case .definition: .definition
        case .both: Bool.random() ? .term : .definition
        }
        question = Question(key: key, answerSide: side, firstAttempt: items[key]?.firstTry == nil)
        skipped.removeAll { $0 == key } // it's back, so there's no skip left to undo
        phase = .asking
    }

    /// Grades an answer. An empty answer counts as "Don't know".
    @discardableResult
    func submit(_ input: String) -> Grade {
        guard phase == .asking, var q = question, var item = items[q.key] else { return .wrong }
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            giveUp()
            return .wrong
        }
        let grade = AnswerGrader.grade(input, answer: q.answerSide.text(of: item.term), english: q.answerSide == .definition)
        q.given = input
        q.grade = grade
        if item.firstTry == nil { item.firstTry = grade != .wrong }
        if grade == .wrong {
            item.misses += 1
            item.status = .learning
            round?.results[q.key] = false
            phase = .wrong
        } else {
            item.status = .mastered
            round?.results[q.key] = true
            phase = .correct
        }
        items[q.key] = item
        question = q
        record(q.key)
        return grade
    }

    func giveUp() {
        guard phase == .asking, var q = question, var item = items[q.key] else { return }
        if item.firstTry == nil { item.firstTry = false }
        item.misses += 1
        item.status = .learning
        items[q.key] = item
        round?.results[q.key] = false
        q.given = nil
        q.grade = .wrong
        question = q
        phase = .wrong
        record(q.key)
    }

    /// Skip is offered while some other term still needs learning.
    var canSkip: Bool {
        guard phase == .asking, let key = question?.key else { return false }
        return items.contains { $0.key != key && $0.value.status != .mastered }
    }

    /// Moves the current term to the very end of everything still to learn, without
    /// counting it as right or wrong.
    func skip() {
        guard canSkip, let q = question, var r = round else { return }
        r.keys.remove(at: r.index) // index now points at the next term in the round
        round = r
        queue.append(q.key)
        skipped.append(q.key)
        if r.index < r.keys.count {
            askCurrent()
        } else if !r.keys.isEmpty {
            endRound()
        } else {
            startRound() // nothing was answered this round, so skip the empty summary
        }
    }

    /// The most recently skipped term that hasn't come back yet. Undo works between questions.
    var lastSkipped: Item? {
        guard phase == .asking || phase == .summary, let key = skipped.last else { return nil }
        return items[key]
    }

    /// Brings the last skipped term back right away.
    func undoSkip() {
        guard lastSkipped != nil, let key = skipped.popLast() else { return }
        queue.removeAll { $0 == key }
        if phase == .asking, var r = round {
            // It may already have been pulled into this round.
            if let later = r.keys.indices.dropFirst(r.index + 1).first(where: { r.keys[$0] == key }) {
                r.keys.remove(at: later)
            }
            r.keys.insert(key, at: r.index) // ask it now; the current term is next
            round = r
            askCurrent()
        } else {
            queue.insert(key, at: 0)
            startRound()
        }
    }

    func overrideCorrect() {
        guard phase == .wrong, let q = question, q.given != nil, var item = items[q.key] else { return }
        item.misses = max(0, item.misses - 1)
        if q.firstAttempt { item.firstTry = true }
        item.status = .mastered
        items[q.key] = item
        round?.results[q.key] = true
        record(q.key)
        next()
    }

    /// After a miss the answer has to be typed correctly to continue. Returns false if it doesn't match.
    @discardableResult
    func checkRetype(_ input: String) -> Bool {
        guard phase == .wrong, let q = question, let item = items[q.key] else { return false }
        let grade = AnswerGrader.grade(input, answer: q.answerSide.text(of: item.term), english: q.answerSide == .definition)
        guard grade != .wrong else { return false }
        next() // still unlearned: it comes back next round
        return true
    }

    func next() {
        guard var r = round else { return }
        r.index += 1
        round = r
        if r.index < r.keys.count { askCurrent() } else { endRound() }
    }

    func continueAfterSummary() {
        guard phase == .summary else { return }
        startRound()
    }

    private func endRound() {
        guard let round else { return }
        // Missed terms lead the next round.
        let missed = round.keys.filter { items[$0] != nil && round.results[$0] != true && items[$0]?.status != .mastered }
        queue = missed.shuffled() + queue
        phase = queue.isEmpty ? .done : .summary
    }

    /// Progress arrived from the website: catch up without interrupting the current question.
    /// Terms mastered there aren't asked again; terms reset there come back at the end.
    /// Returns true if the phase changed.
    @discardableResult
    func apply(progress: [String: StudyRecord]) -> Bool {
        guard !missedOnly else { return false }
        let inQuestion = [.asking, .correct, .wrong].contains(phase)
        let busy = inQuestion && phase != .asking ? question?.key : nil // just answered here, so ours is newest
        var changed = false
        for (key, item) in items where key != busy {
            let saved = progress[key]
            let status = saved?.status ?? .new
            guard status != item.status || (saved?.misses ?? 0) != item.misses else { continue }
            items[key]?.status = status
            items[key]?.misses = saved?.misses ?? 0
            items[key]?.firstTry = saved?.firstTry
            changed = true
        }
        guard changed else { return false }
        let notMastered = { (key: String) in self.items[key]?.status != .mastered }
        queue = queue.filter(notMastered)
        var scheduled = Set(queue)
        if var r = round {
            let from = inQuestion ? min(r.index + 1, r.keys.count) : r.keys.count
            r.keys = Array(r.keys[..<from]) + r.keys[from...].filter(notMastered)
            round = r
            scheduled.formUnion(r.keys[from...])
            if inQuestion {
                if let key = question?.key { scheduled.insert(key) }
                // Missed earlier this round: endRound puts these back in the queue.
                scheduled.formUnion(r.keys[..<r.index].filter { r.results[$0] != true })
            }
        }
        queue += order.filter { notMastered($0) && !scheduled.contains($0) }
        let before = phase
        if phase == .summary && queue.isEmpty { phase = .done }
        if phase == .done && !queue.isEmpty { startRound() }
        return phase != before
    }

    /// Keeps the session in step with a fresh download from the cloud.
    func reconcile(with terms: [Term], isSelected: (String) -> Bool, progress: [String: StudyRecord] = [:]) {
        let all = Dictionary(terms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for key in Array(items.keys) {
            if let t = all[key] { items[key]?.term = t } else { items[key] = nil }
        }
        order = order.filter { items[$0] != nil }
        if !missedOnly {
            for t in terms where isSelected(t.category) && items[t.id] == nil {
                var item = Item(term: t)
                if let saved = progress[t.id] {
                    item.status = saved.status
                    item.misses = saved.misses
                    item.firstTry = saved.firstTry
                }
                items[t.id] = item
                order.append(t.id)
                if item.status != .mastered { queue.append(t.id) }
            }
        }
        queue = queue.filter { items[$0] != nil }
        skipped = skipped.filter { items[$0] != nil }
        if var r = round {
            let inQuestion = [.asking, .correct, .wrong].contains(phase)
            let currentGone = inQuestion && r.index < r.keys.count && items[r.keys[r.index]] == nil
            let before = r.keys.prefix(r.index).filter { items[$0] != nil }.count
            r.keys = r.keys.filter { items[$0] != nil }
            r.index = before
            round = r
            if currentGone {
                if r.index < r.keys.count { askCurrent() } else { endRound() }
            }
        }
        if phase == .done && !queue.isEmpty { phase = .summary }
    }
}
