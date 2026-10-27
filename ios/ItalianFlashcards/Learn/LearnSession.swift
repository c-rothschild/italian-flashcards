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
@MainActor
@Observable
final class LearnSession {
    enum Phase: Equatable { case asking, correct, wrong, summary, done }
    enum Status { case new, learning, mastered }

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
    let missedOnly: Bool
    var answerMode: AnswerMode

    init(terms: [Term], answerMode: AnswerMode, missedOnly: Bool = false) {
        self.answerMode = answerMode
        self.missedOnly = missedOnly
        for t in terms where items[t.id] == nil {
            items[t.id] = Item(term: t)
            order.append(t.id)
        }
        queue = order.shuffled()
        startRound()
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
    }

    func overrideCorrect() {
        guard phase == .wrong, let q = question, q.given != nil, var item = items[q.key] else { return }
        item.misses = max(0, item.misses - 1)
        if q.firstAttempt { item.firstTry = true }
        item.status = .mastered
        items[q.key] = item
        round?.results[q.key] = true
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
        let missed = round.keys.filter { items[$0] != nil && round.results[$0] != true }
        queue = missed.shuffled() + queue
        phase = queue.isEmpty ? .done : .summary
    }

    /// Keeps the session in step with a fresh download from the cloud.
    func reconcile(with terms: [Term], isSelected: (String) -> Bool) {
        let all = Dictionary(terms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for key in Array(items.keys) {
            if let t = all[key] { items[key]?.term = t } else { items[key] = nil }
        }
        order = order.filter { items[$0] != nil }
        if !missedOnly {
            for t in terms where isSelected(t.category) && items[t.id] == nil {
                items[t.id] = Item(term: t)
                order.append(t.id)
                queue.append(t.id)
            }
        }
        queue = queue.filter { items[$0] != nil }
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
