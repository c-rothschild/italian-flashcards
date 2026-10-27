import Foundation

/// One flashcard. `term` is the Italian side, `definition` the English side.
struct Term: Identifiable, Hashable, Sendable {
    let term: String
    let definition: String
    let category: String // "" = uncategorized

    var id: String { term + "\u{0}" + definition }
    var categoryLabel: String { Term.label(for: category) }

    static func label(for category: String) -> String {
        category.isEmpty ? "Uncategorized" : category
    }
}

/// Which side of a card is being shown or asked for.
enum CardSide: String, CaseIterable, Identifiable {
    case term, definition
    var id: String { rawValue }
    var languageName: String { self == .term ? "Italian" : "English" }
    var opposite: CardSide { self == .term ? .definition : .term }

    func text(of term: Term) -> String { self == .term ? term.term : term.definition }
}

/// Parses data/terms.csv (term,definition,category). Mirrors the website's server:
/// a file without the header row is the original 2-column format, where an unquoted
/// comma belongs to the definition.
enum TermsCSV {
    static func parse(_ text: String) -> [Term] {
        var terms: [Term] = []
        var seen = Set<String>()
        var hasHeader = false
        for (i, row) in rows(text).enumerated() {
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            if i == 0, row.prefix(2).map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) == ["term", "definition"] {
                hasHeader = true
                continue
            }
            var f = row
            if !hasHeader {
                f = [row[0], row.dropFirst().joined(separator: ","), ""]
            } else if f.count < 3 {
                f += Array(repeating: "", count: 3 - f.count)
            } else if f.count > 3 {
                f = [f[0], f[1..<(f.count - 1)].joined(separator: ","), f[f.count - 1]]
            }
            let t = Term(term: f[0].trimmingCharacters(in: .whitespaces),
                         definition: f[1].trimmingCharacters(in: .whitespaces),
                         category: f[2].trimmingCharacters(in: .whitespaces))
            guard !t.term.isEmpty, seen.insert(t.id).inserted else { continue }
            terms.append(t)
        }
        return terms
    }

    /// RFC 4180 rows: quoted fields may contain commas, newlines and doubled quotes.
    static func rows(_ text: String) -> [[String]] {
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(String(field))
                    field = String.UnicodeScalarView()
                case "\n", "\r":
                    if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                    row.append(String(field))
                    rows.append(row)
                    row = []
                    field = String.UnicodeScalarView()
                default:
                    field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(String(field))
            rows.append(row)
        }
        return rows
    }
}
