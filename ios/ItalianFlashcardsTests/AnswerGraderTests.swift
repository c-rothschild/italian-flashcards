import XCTest
@testable import ItalianFlashcards

/// Same cases as the website's grader checks, so both apps grade identically.
final class AnswerGraderTests: XCTestCase {
    private let cases: [(input: String, answer: String, english: Bool, expected: Grade)] = [
        ("Hi", "hi/bye", true, .correct),
        ("bye", "hi/bye", true, .correct),
        ("hi/bye", "hi/bye", true, .correct),
        ("good day", "good morning, good day", true, .correct),
        ("Good morning, good day!", "good morning, good day", true, .correct),
        ("student", "student (male)", true, .correct),
        ("student (male)", "student (male)", true, .correct),
        ("bottle of water", "a bottle of water", true, .correct),
        ("the bottle of water", "a bottle of water", true, .correct),
        ("what's your name", "What is your name?", true, .wrong),
        ("what is your name", "What is your name?", true, .correct),
        ("my name is", "My name is ...", true, .correct),
        ("21", "21", true, .correct),
        ("ventitré", "ventitré", false, .correct),
        ("ventitre", "ventitré", false, .accent),
        ("Caffe", "caffè", false, .accent),
        ("citta", "città", false, .accent),
        ("mi chiamo", "Mi chiamo...", false, .correct),
        ("come stai", "Come stai?", false, .correct),
        ("olio d’oliva", "olio d'oliva", false, .correct),
        ("olio d' oliva", "olio d'oliva", false, .correct),
        ("bottiglia d acqua", "bottiglia d'acqua", false, .wrong),
        ("gatta", "gatto", false, .wrong),
        ("benissimo", "bene", false, .wrong),
        ("serie tv", "serie TV", false, .correct),
        ("", "cane", false, .wrong),
        ("lei è", "lui/lei è", false, .correct),
        ("lui e", "lui/lei è", false, .accent),
        ("è", "lui/lei è", false, .correct),
        ("parlo", "io parlo", false, .correct),
        ("io parlo", "io parlo", false, .correct),
        ("tu parlo", "io parlo", false, .wrong),
        ("he speaks", "he/she speaks (also formal you)", true, .correct),
        ("she speaks", "he/she speaks (also formal you)", true, .correct),
        ("you speak", "you speak (informal)", true, .correct),
        ("cameriera", "cameriere / cameriera", false, .correct),
        ("waitress", "waiter / waitress", true, .correct),
        ("office worker", "office worker (m / f)", true, .correct),
        ("I do", "I do, I make", true, .correct),
        ("he makes", "he/she does, makes (also formal you)", true, .wrong),
        ("he does", "he/she does, makes (also formal you)", true, .correct),
        ("an", "a, an (fem.; before a vowel)", true, .correct),
        ("un'idea", "un'idea", false, .correct),
        ("un idea", "un'idea", false, .wrong),
        ("sposato", "Sei sposato/a?", false, .wrong),
        ("sei sposata", "Sei sposato/a?", false, .correct),
        ("gelato", "gelato/ice cream", true, .correct),
        ("ice cream", "gelato/ice cream", true, .correct),
    ]

    func testWebsiteCases() {
        for c in cases {
            XCTAssertEqual(AnswerGrader.grade(c.input, answer: c.answer, english: c.english), c.expected,
                           "\(c.input.debugDescription) vs \(c.answer.debugDescription)")
        }
    }

    func testEveryBundledCardAcceptsItsOwnAnswer() throws {
        let url = try XCTUnwrap(Bundle(for: TermRepository.self).url(forResource: "terms", withExtension: "csv"))
        let terms = TermsCSV.parse(try String(contentsOf: url, encoding: .utf8))
        XCTAssertGreaterThan(terms.count, 100)
        for t in terms {
            XCTAssertEqual(AnswerGrader.grade(t.term, answer: t.term, english: false), .correct, t.term)
            XCTAssertEqual(AnswerGrader.grade(t.definition, answer: t.definition, english: true), .correct, t.definition)
        }
    }
}

final class TermsCSVTests: XCTestCase {
    func testHeaderQuotedCommasAndCRLF() {
        let csv = "\u{FEFF}term,definition,category\r\nbuongiorno,\"good morning, good day\",Greetings\r\n\"say \"\"ciao\"\"\",greet,\r\n\r\ncane,dog,Animals"
        let terms = TermsCSV.parse(csv)
        XCTAssertEqual(terms, [
            Term(term: "buongiorno", definition: "good morning, good day", category: "Greetings"),
            Term(term: "say \"ciao\"", definition: "greet", category: ""),
            Term(term: "cane", definition: "dog", category: "Animals"),
        ])
    }

    func testHeaderlessTwoColumnFileKeepsCommasInDefinition() {
        let terms = TermsCSV.parse("ciao,hi\nbuongiorno,good morning, good day\n")
        XCTAssertEqual(terms.map(\.definition), ["hi", "good morning, good day"])
        XCTAssertEqual(terms.map(\.category), ["", ""])
    }

    func testDuplicatesAndBlankTermsAreDropped() {
        let terms = TermsCSV.parse("term,definition,category\ncane,dog,A\ncane,dog,B\n,orphan,A\nuno,1,Numbers\nuno,\"a, an\",Articles\n")
        XCTAssertEqual(terms.map(\.id), ["cane\u{0}dog", "uno\u{0}1", "uno\u{0}a, an"])
    }
}
