import XCTest
@testable import ItalianFlashcards

@MainActor
final class LearnSessionTests: XCTestCase {
    private func terms(_ n: Int) -> [Term] {
        (1...n).map { Term(term: "parola\($0)", definition: "word\($0)", category: "Test") }
    }

    private func answer(_ s: LearnSession) -> String { s.expectedAnswer ?? "" }

    func testRoundsOfSevenAndCorrectAnswersMaster() {
        let s = LearnSession(terms: terms(10), answerMode: .term)
        XCTAssertEqual(s.round?.keys.count, 7)
        for _ in 0..<7 {
            XCTAssertEqual(s.phase, .asking)
            XCTAssertEqual(s.submit(answer(s)), .correct)
            s.next()
        }
        XCTAssertEqual(s.phase, .summary)
        XCTAssertEqual(s.masteredCount, 7)
        s.continueAfterSummary()
        XCTAssertEqual(s.round?.keys.count, 3)
    }

    func testMissedTermMustBeRetypedAndLeadsNextRound() {
        let s = LearnSession(terms: terms(8), answerMode: .term)
        let missedKey = s.question!.key
        XCTAssertEqual(s.submit("sbagliato"), .wrong)
        XCTAssertEqual(s.phase, .wrong)
        XCTAssertFalse(s.checkRetype("still wrong"))
        XCTAssertEqual(s.phase, .wrong, "can't continue without typing the answer")
        XCTAssertTrue(s.checkRetype(answer(s)))
        while s.phase == .asking {
            s.submit(answer(s))
            s.next()
        }
        XCTAssertEqual(s.phase, .summary)
        XCTAssertEqual(s.items[missedKey]?.status, .learning)
        s.continueAfterSummary()
        XCTAssertEqual(s.round?.keys.first, missedKey, "missed term comes first next round")
    }

    func testEmptyAnswerIsDontKnowWithoutOverride() {
        let s = LearnSession(terms: terms(3), answerMode: .definition)
        s.submit("   ")
        XCTAssertEqual(s.phase, .wrong)
        XCTAssertNil(s.question?.given)
        s.overrideCorrect() // not allowed after "Don't know"
        XCTAssertEqual(s.phase, .wrong)
        XCTAssertEqual(s.currentItem?.misses, 1)
    }

    func testOverrideCountsAsCorrectFirstTry() {
        let s = LearnSession(terms: terms(3), answerMode: .term)
        let key = s.question!.key
        s.submit("my own answer")
        s.overrideCorrect()
        XCTAssertEqual(s.items[key]?.status, .mastered)
        XCTAssertEqual(s.items[key]?.misses, 0)
        XCTAssertEqual(s.items[key]?.firstTry, true)
        XCTAssertNotEqual(s.question?.key, key, "moved on to the next term")
    }

    func testFinishesWhenEverythingIsMastered() {
        let s = LearnSession(terms: terms(3), answerMode: .both)
        s.submit("nope")
        s.checkRetype(answer(s))
        while s.phase != .done {
            if s.phase == .summary { s.continueAfterSummary(); continue }
            s.submit(answer(s))
            s.next()
        }
        XCTAssertEqual(s.masteredCount, 3)
        XCTAssertEqual(s.firstTryCount, 2)
        XCTAssertEqual(s.mostMissed.count, 1)
    }

    func testReconcileDropsDeletedCurrentTermAndAddsNewOnes() {
        let all = terms(4)
        let s = LearnSession(terms: all, answerMode: .term)
        let current = s.question!.key
        let remaining = all.filter { $0.id != current } + [Term(term: "nuovo", definition: "new", category: "Test")]
        s.reconcile(with: remaining, isSelected: { _ in true })
        XCTAssertNil(s.items[current])
        XCTAssertNotEqual(s.question?.key, current)
        XCTAssertEqual(s.total, 4)
        XCTAssertNotNil(s.items[Term(term: "nuovo", definition: "new", category: "Test").id])
    }
}
