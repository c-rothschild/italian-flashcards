import Foundation

/// How a typed answer compares with the expected one.
enum Grade: Equatable {
    case correct
    case accent // right apart from accents (Italian answers only)
    case wrong
}

/// Answer checking, ported from the website's Learn mode (static/app.js) so both
/// grade the same way. Ignores case, punctuation and extra spaces; any one part of a
/// "hi/bye" or "good morning, good day" answer counts; "(notes)" are optional; English
/// answers may drop a leading "the/a/an/to"; Italian answers may drop the subject
/// pronoun ("lui/lei parla" -> "parla"); a missing or wrong accent counts, with a reminder.
enum AnswerGrader {
    static func grade(_ input: String, answer: String, english: Bool) -> Grade {
        let accepted = acceptedAnswers(answer, english: english)
        let given = normalize(input)
        let tries = english ? [given, dropArticle(given)] : [given]
        if tries.contains(where: accepted.contains) { return .correct }
        let loose = Set(accepted.map(stripAccents))
        if tries.contains(where: { loose.contains(stripAccents($0)) }) { return english ? .correct : .accent }
        return .wrong
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().precomposedStringWithCanonicalMapping
            .regexReplace("[’‘`´]", "'")
            .regexReplace("\\s*/\\s*", "/")
            .regexReplace("\\s*'\\s*", "'")
            .regexReplace("[.,!?¿¡;:\"“”«»…()\\[\\]]", " ")
            .regexReplace("\\s+", " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func stripAccents(_ s: String) -> String {
        let scalars = s.decomposedStringWithCanonicalMapping.unicodeScalars.filter { !(0x300...0x36F).contains($0.value) }
        return String(String.UnicodeScalarView(scalars)).precomposedStringWithCanonicalMapping
    }

    static func dropArticle(_ s: String) -> String { s.regexReplace("^(the|a|an|to) ", "") }

    /// Italian usually drops the subject pronoun: "lui/lei parla" -> "parla".
    static func dropPronoun(_ s: String) -> String { s.regexReplace("^(io|tu|lui|lei|noi|voi|loro) (?=\\S)", "") }

    /// Word-level alternatives: "lui/lei è" -> "lui è", "lei è". A one-letter option swaps
    /// the word's last letter: "sposato/a" -> "sposato", "sposata".
    static func expandSlashes(_ n: String) -> [String] {
        var combos = [""]
        for word in n.split(separator: " ") {
            let raw = word.split(separator: "/").map(String.init)
            guard let first = raw.first else { continue }
            let options = raw.enumerated().map { i, o in
                i > 0 && o.count == 1 && first.count > 2 ? String(first.dropLast()) + o : o
            }
            combos = Array(combos.flatMap { c in options.map { c.isEmpty ? $0 : c + " " + $0 } }.prefix(64))
        }
        return combos
    }

    static func acceptedAnswers(_ answer: String, english: Bool) -> Set<String> {
        var out = Set<String>()
        func add(_ s: String) {
            let n = normalize(s)
            guard !n.isEmpty else { return }
            for v in [n] + expandSlashes(n) {
                out.insert(v)
                if english {
                    let d = dropArticle(v)
                    if !d.isEmpty { out.insert(d) }
                } else {
                    let d = dropPronoun(v)
                    if d != v { out.insert(d) }
                }
            }
        }
        let noNotes = answer.regexReplace("\\([^)]*\\)", " ")
        for base in [answer, noNotes] {
            add(base)
            base.components(separatedBy: CharacterSet(charactersIn: ",;")).forEach(add)
            base.components(separatedBy: CharacterSet(charactersIn: "/,;")).forEach(add)
        }
        return out
    }
}

extension String {
    func regexReplace(_ pattern: String, _ replacement: String) -> String {
        replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}
