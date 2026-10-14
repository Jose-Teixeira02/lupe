import Foundation

/// Exports the deck for Anki ("File → Import", tab-separated, fields in this order) or as CSV.
public enum DeckExporter {
    public static let ankiFields = ["German", "Meaning (EN)", "Meaning (PT)", "Grammar", "Context", "Context translation", "Tags"]

    public static func ankiTSV(_ cards: [Card]) -> String {
        var lines = [
            "#separator:tab",
            "#html:false",
            "#columns:" + ankiFields.joined(separator: "\t"),
            "#tags column:\(ankiFields.count)",
        ]
        for c in cards where c.status != .suspended {
            let e = c.latestEncounter
            let tags = ["lupe", c.source.rawValue, c.pos?.label ?? c.kind.rawValue, c.status == .known ? "known" : nil]
                .compactMap { $0 }.joined(separator: " ")
            let row = [c.display, c.meanings["en"] ?? "", c.meanings["pt"] ?? "", grammar(c), e?.sentence ?? "", e?.translation ?? "", tags]
            lines.append(row.map(clean).joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func csv(_ cards: [Card]) -> String {
        var lines = [["german", "meaning_en", "meaning_pt", "grammar", "context", "context_translation", "state", "due", "status"].joined(separator: ",")]
        let f = ISO8601DateFormatter()
        for c in cards {
            let e = c.latestEncounter
            let row = [c.display, c.meanings["en"] ?? "", c.meanings["pt"] ?? "", grammar(c), e?.sentence ?? "",
                       e?.translation ?? "", c.memory.state.rawValue, f.string(from: c.memory.due), c.status.rawValue]
            lines.append(row.map(quote).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func grammar(_ c: Card) -> String {
        guard let pos = c.pos else { return "" }
        if pos == .noun { return c.forms.isEmpty ? "noun" : "noun · pl. \(c.forms)" }
        return c.forms.isEmpty ? pos.label : "\(pos.label) · \(c.forms)"
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
