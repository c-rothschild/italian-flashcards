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

    func testSkipMovesTermToTheVeryEnd() {
        let s = LearnSession(terms: terms(20), answerMode: .term)
        let skipped = s.question!.key
        s.skip()
        XCTAssertEqual(s.phase, .asking)
        XCTAssertNotEqual(s.question?.key, skipped)
        XCTAssertEqual(s.items[skipped]?.status, .new, "skipping isn't a right or wrong answer")
        XCTAssertEqual(s.items[skipped]?.misses, 0)
        XCTAssertEqual(s.round?.keys.count, 6)

        var asked: [String] = []
        while s.phase != .done {
            if s.phase == .summary { s.continueAfterSummary(); continue }
            asked.append(s.question!.key)
            s.submit(answer(s))
            s.next()
        }
        XCTAssertEqual(asked.count, 20)
        XCTAssertEqual(asked.last, skipped, "asked after every other term")
    }

    func testSkippingAWholeRoundStartsTheNextWithoutAnEmptySummary() {
        let s = LearnSession(terms: terms(2), answerMode: .term)
        s.skip()
        s.skip()
        XCTAssertEqual(s.phase, .asking)
        XCTAssertEqual(s.round?.number, 2)
        XCTAssertEqual(s.round?.keys.count, 2)
    }

    func testSkipUnavailableForTheLastTermLeft() {
        let s = LearnSession(terms: terms(2), answerMode: .term)
        XCTAssertTrue(s.canSkip)
        s.submit(answer(s))
        s.next()
        XCTAssertFalse(s.canSkip)
        let key = s.question?.key
        s.skip()
        XCTAssertEqual(s.question?.key, key)
    }

    func testUndoSkipBringsTermsBackMostRecentFirst() {
        let s = LearnSession(terms: terms(20), answerMode: .term)
        XCTAssertNil(s.lastSkipped)
        let first = s.question!.key
        s.skip()
        let second = s.question!.key
        s.skip()
        let third = s.question!.key

        s.undoSkip()
        XCTAssertEqual(s.question?.key, second)
        XCTAssertEqual(s.lastSkipped?.term.id, first)
        s.undoSkip()
        XCTAssertEqual(s.question?.key, first)
        XCTAssertNil(s.lastSkipped)
        XCTAssertEqual(s.round?.keys.count, 7)
        XCTAssertEqual(Array(s.round!.keys[s.round!.index...].prefix(3)), [first, second, third])
        XCTAssertFalse(s.queue.contains(first))
        XCTAssertEqual(s.items[first]?.status, .new)
    }

    func testUndoSkipFromTheRoundSummaryStartsWithTheSkippedTerm() {
        let s = LearnSession(terms: terms(10), answerMode: .term)
        for _ in 0..<6 {
            s.submit(answer(s))
            s.next()
        }
        let last = s.question!.key
        s.skip()
        XCTAssertEqual(s.phase, .summary)
        XCTAssertNotNil(s.lastSkipped)
        s.undoSkip()
        XCTAssertEqual(s.phase, .asking)
        XCTAssertEqual(s.round?.number, 2)
        XCTAssertEqual(s.question?.key, last)
    }

    func testNoUndoOnceTheSkippedTermComesBack() {
        let s = LearnSession(terms: terms(3), answerMode: .term)
        let skipped = s.question!.key
        s.skip()
        s.submit(answer(s))
        XCTAssertNil(s.lastSkipped, "finish the current question first")
        s.next()
        XCTAssertNotNil(s.lastSkipped)
        s.submit(answer(s))
        s.next()
        XCTAssertEqual(s.phase, .summary)
        XCTAssertNotNil(s.lastSkipped, "can still undo from the summary")
        s.continueAfterSummary()
        XCTAssertEqual(s.question?.key, skipped)
        XCTAssertNil(s.lastSkipped)
    }

    private func saved(_ status: StudyStatus, misses: Int = 0) -> StudyRecord {
        StudyRecord(status: status, misses: misses, firstTry: status == .mastered ? true : (status == .new ? nil : false), updated: 1)
    }

    func testResumesFromSavedProgress() {
        let all = terms(10)
        var progress: [String: StudyRecord] = [:]
        for t in all.prefix(4) { progress[t.id] = saved(.mastered) }
        progress[all[9].id] = saved(.learning, misses: 2)
        let s = LearnSession(terms: all, answerMode: .term, progress: progress)
        XCTAssertEqual(s.masteredCount, 4)
        XCTAssertEqual(s.learningCount, 1)
        XCTAssertEqual(s.question?.key, all[9].id, "still-learning terms come first")
        XCTAssertEqual((s.round?.keys.count ?? 0) + s.queue.count, 6, "mastered terms aren't asked")
        XCTAssertEqual(s.items[all[9].id]?.misses, 2)

        var recorded: [String: LearnSession.Item] = [:]
        s.onRecord = { recorded[$0] = $1 }
        s.submit(answer(s))
        XCTAssertEqual(recorded[all[9].id]?.status, .mastered)
        s.next()
        s.submit("wrong")
        XCTAssertEqual(recorded[s.question!.key]?.status, .learning)
    }

    func testEverythingAlreadyMasteredIsDone() {
        let all = terms(3)
        let s = LearnSession(terms: all, answerMode: .term, progress: Dictionary(uniqueKeysWithValues: all.map { ($0.id, saved(.mastered)) }))
        XCTAssertEqual(s.phase, .done)
    }

    func testPracticeMissedDoesNotRecord() {
        let s = LearnSession(terms: terms(3), answerMode: .term, missedOnly: true, progress: [terms(1)[0].id: saved(.mastered)])
        XCTAssertEqual(s.masteredCount, 0, "practice ignores saved progress")
        var calls = 0
        s.onRecord = { _, _ in calls += 1 }
        s.submit(answer(s))
        XCTAssertEqual(calls, 0)
    }

    func testProgressFromTheWebsiteIsAppliedMidRound() {
        let all = terms(20)
        let s = LearnSession(terms: all, answerMode: .term)
        let current = s.question!.key
        let upcoming = Array(s.round!.keys[1...2])
        let queued = s.queue[3]
        s.submit(answer(s)) // answered here, so it's mastered
        let answered = current
        s.next()
        let asking = s.question!.key

        var website: [String: StudyRecord] = [answered: StudyRecord(status: .mastered, misses: 0, firstTry: true, updated: 9)]
        for key in upcoming.filter({ $0 != asking }) + [queued] { website[key] = saved(.mastered) }
        website[asking] = saved(.mastered)
        XCTAssertFalse(s.apply(progress: website))
        XCTAssertEqual(s.question?.key, asking, "the current question stays")
        XCTAssertFalse(s.queue.contains(queued))
        for key in upcoming where key != asking { XCTAssertFalse(s.round!.keys[(s.round!.index + 1)...].contains(key)) }

        // Reset on the website: the answered term comes back at the end.
        website[answered] = saved(.new)
        s.apply(progress: website)
        XCTAssertEqual(s.queue.last, answered)
        XCTAssertEqual(s.items[answered]?.status, .new)

        var asked: [String] = []
        while s.phase != .done {
            if s.phase == .summary { s.continueAfterSummary(); continue }
            asked.append(s.question!.key)
            s.submit(answer(s))
            s.next()
        }
        XCTAssertFalse(asked.contains(queued), "mastered on the website, so not asked")
        XCTAssertEqual(asked.last, answered)
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
