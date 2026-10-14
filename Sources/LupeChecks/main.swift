import AppKit
import Foundation
import LupeCore

// A small self-check suite (swift test needs full Xcode; this runs with the Command Line Tools).
// Run: swift run LupeChecks            (add --live to include on-device Translation/AI checks)

setvbuf(stdout, nil, _IONBF, 0)
var passed = 0
var failed: [String] = []

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if condition() { passed += 1 } else { failed.append("line \(line): \(message)"); print("  ✗ \(message)") }
}

func section(_ name: String) { print("• \(name)") }

/// Deterministic translator for tests.
struct FakeTranslator: Translator {
    var table: [String: String]
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        if let t = table[text] { return t }
        throw TranslatorError.empty
    }
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lupe-checks-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
func run() async {
    let live = CommandLine.arguments.contains("--live")
    if live {
        let early = await AppleTranslator().status(from: "en", to: "de")
        print("  (early en→de status: \(early))")
    }

    // MARK: Lexicon
    section("Lexicon pack")
    let lexicon: Lexicon
    do {
        lexicon = try LupePaths.loadLexicon("de")
    } catch {
        print("  ✗ could not load pack: \(error)")
        failed.append("load pack")
        return
    }
    print("  \(lexicon.entries.count) entries")
    check(lexicon.entries.count > 500, "pack has > 500 entries")
    check(Set(lexicon.entries.map(\.id)).count == lexicon.entries.count, "entry ids are unique")
    let gendered = lexicon.entries.filter { $0.pos == .noun }.allSatisfy { $0.gender != nil }
    check(gendered, "every noun has a gender")
    let missingGloss = lexicon.entries.filter { ($0.glosses["en"] ?? []).isEmpty || ($0.glosses["pt"] ?? []).isEmpty }
    check(missingGloss.isEmpty, "every entry has EN and PT glosses (missing: \(missingGloss.prefix(5).map(\.lemma)))")
    let badCefr = lexicon.entries.filter { !["A1", "A2", "B1", "B2", "C1"].contains($0.cefr) }
    check(badCefr.isEmpty, "valid CEFR levels (bad: \(badCefr.prefix(5).map(\.lemma)))")
    check(lexicon.entry(id: "Bank#n") != nil && lexicon.entry(id: "Bank#n#2") != nil, "homographs Bank/Bank get distinct ids")
    // Accidental duplicates show up as "#2" ids; only real homographs are allowed.
    let homographs: Set<String> = ["Bank#n#2", "See#n#2", "Leiter#n#2", "Steuer#n#2", "Band#n#2", "Kiefer#n#2", "Schild#n#2", "Gehalt#n#2", "Tor#n#2", "Erbe#n#2", "Mangel#n#2", "Moment#n#2"]
    let dupes = lexicon.entries.filter { $0.id.hasSuffix("#2") || $0.id.hasSuffix("#3") }.map(\.id).filter { !homographs.contains($0) }
    check(dupes.isEmpty, "no accidental duplicate entries (found: \(dupes))")
    let softHyphen = lexicon.entries.filter { $0.lemma.unicodeScalars.contains { $0.value == 0xAD || $0.value == 0x200B } }
    check(softHyphen.isEmpty, "no invisible characters in lemmas (\(softHyphen.map(\.lemma)))")

    check(lexicon.entries(forGerman: "Tische").first?.lemma == "Tisch", "plural Tische → Tisch")
    check(lexicon.entries(forGerman: "Häuser").first?.lemma == "Haus", "plural Häuser → Haus")
    check(lexicon.entries(forGerman: "fuhr").first?.lemma == "fahren", "Präteritum fuhr → fahren")
    check(lexicon.entries(forGerman: "gefahren").first?.lemma == "fahren", "Partizip gefahren → fahren")
    check(lexicon.entries(forGerman: "besten").first?.lemma == "gut", "superlative besten → gut")
    check(lexicon.entries(forGloss: "better", language: "en").first?.lemma == "besser", "EN better → besser")
    check(lexicon.entries(forGerman: "kommt").first?.lemma == "kommen", "kommt → kommen (not ankommen)")
    check(lexicon.display(lexicon.entries(forGerman: "Tisch")[0]) == "der Tisch", "display adds article")
    check(lexicon.display(lexicon.entries(forGerman: "Leute")[0]) == "die Leute", "plural-only noun uses die")
    check(lexicon.entries(forGloss: "table", language: "en").first?.lemma == "Tisch", "EN gloss table → Tisch")
    check(lexicon.entries(forGloss: "look for", language: "en").contains { $0.lemma == "suchen" }, "EN multiword gloss 'look for' → suchen")
    check(lexicon.entries(forGloss: "mesa", language: "pt").first?.lemma == "Tisch", "PT gloss mesa → Tisch")
    check(lexicon.entries(forGloss: "levantar", language: "pt").contains { $0.lemma == "aufstehen" }, "PT reflexive levantar-se indexed as levantar")
    check(lexicon.entries(forGloss: "telemóvel", language: "pt").first?.lemma == "Handy", "PT-PT telemóvel → Handy")
    check(lexicon.bestEntry(forGerman: "Essen", capitalized: true)?.pos == .noun, "capitalised Essen → noun")
    check(lexicon.bestEntry(forGerman: "essen", capitalized: false)?.pos == .verb, "lowercase essen → verb")
    check(Lexicon.glossKeys("husband", language: "en", pos: .noun) == ["husband"], "gloss keys keep words containing 'sb'")

    // MARK: Text tools
    section("Text tools")
    check(TextTools.detectLanguage("Ich habe gestern meinen Schlüssel verloren.", candidates: ["de", "en", "pt"]) == "de", "detects German")
    check(TextTools.detectLanguage("I lost my keys yesterday at the station.", candidates: ["de", "en", "pt"]) == "en", "detects English")
    check(TextTools.detectLanguage("Ontem perdi as minhas chaves na estação.", candidates: ["de", "en", "pt"]) == "pt", "detects Portuguese")
    let toks = TextTools.analyze("The children were running with bigger dogs", language: "en")
    check(toks.first { $0.text == "children" }?.lemma == "child", "EN lemma children → child")
    let de = TextTools.analyze("Die Kinder spielten im Garten", language: "de")
    check(de.first { $0.text == "spielten" }?.lemma == "spielen", "DE lemma spielten → spielen")

    // MARK: FSRS
    section("FSRS scheduling")
    let fsrs = FSRS()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var m = MemoryState(due: t0)
    m = fsrs.review(m, rating: .good, now: t0)
    check(m.state == .learning && abs(m.due.timeIntervalSince(t0) - 600) < 1, "new → Good → 10 min learning step")
    let t1 = t0 + 600
    m = fsrs.review(m, rating: .good, now: t1)
    let days = m.due.timeIntervalSince(t1) / 86_400
    check(m.state == .review && days >= 3 && days <= 5, "learning → Good graduates (~4 days, got \(days))")
    let preview = fsrs.preview(m, now: m.due)
    check(preview[.hard]! < preview[.good]! && preview[.good]! < preview[.easy]!, "hard < good < easy intervals")
    let lapsed = fsrs.review(m, rating: .again, now: m.due)
    check(lapsed.state == .relearning && lapsed.lapses == 1 && lapsed.stability < m.stability, "Again on review → relearning, stability drops")
    var g = m
    var last = 0.0
    var increasing = true
    for _ in 0..<5 {
        let now = g.due
        g = fsrs.review(g, rating: .good, now: now)
        let interval = g.due.timeIntervalSince(now)
        if interval <= last { increasing = false }
        last = interval
    }
    check(increasing, "repeated Good keeps growing intervals (last \(FSRS.format(last)))")
    check(abs(fsrs.intervalDays(stability: 10) - 10) < 0.5, "at 90 % retention interval ≈ stability")
    check(FSRS.format(90) == "2m" && FSRS.format(86_400 * 3) == "3d", "interval formatting")

    // MARK: Journey
    section("Journey")
    let jdir = tempDir()
    let journey = Journey(language: "de", directory: jdir)
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Lisbon")!
    journey.calendar = cal
    let base = cal.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12))!
    for d in 0..<3 {
        journey.clock = { cal.date(byAdding: .day, value: d, to: base)! }
        for _ in 0..<6 { journey.record(.review(.good)) }
    }
    journey.clock = { cal.date(byAdding: .day, value: 3, to: base)! }
    check(journey.streak == 3, "streak counts 3 days and today unfinished doesn't break it (got \(journey.streak))")
    for _ in 0..<5 { journey.record(.review(.good)) }
    check(journey.streak == 4, "today counts once threshold reached (got \(journey.streak))")
    journey.clock = { cal.date(byAdding: .day, value: 6, to: base)! }
    check(journey.streak == 0, "a gap resets the streak")
    check(journey.bestStreak == 4, "best streak remembered (got \(journey.bestStreak))")
    let pos = Journey.position(knownWords: 750)
    check(pos.current?.level == "A1" && pos.next?.level == "A2" && abs(pos.progress - 0.5) < 0.01, "CEFR path position")
    journey.flush()
    let journey2 = Journey(language: "de", directory: jdir)
    check(journey2.totalXP == journey.totalXP && journey2.totalXP > 0, "journey persists")

    // MARK: Word bank
    section("Word bank")
    let dir = tempDir()
    let bank = WordBank(language: "de", directory: dir)
    let tisch = lexicon.entries(forGerman: "Tisch")[0]
    let enc = Encounter(sentence: "Put it on the table.", translation: "Leg es auf den Tisch.", language: "en", app: "Safari")
    let (card, created) = bank.add(term: "Tisch", entry: tisch, display: "der Tisch", meanings: ["en": "table"], encounter: enc, source: .hover)
    check(created && card.gender == .masculine, "adds card with gender")
    let (_, created2) = bank.add(term: "Tisch", entry: tisch, display: "der Tisch", meanings: ["pt": "mesa"],
                                 encounter: Encounter(sentence: "A mesa é grande.", translation: nil, language: "pt", app: nil), source: .hover)
    check(!created2 && bank.cards.count == 1, "de-duplicates by entry")
    check(bank.cards[0].encounters.count == 2 && bank.cards[0].meanings["pt"] == "mesa", "merges encounter and meanings")
    check(bank.dueQueue().count == 1, "new card is due")
    bank.review(card.id, rating: .easy)
    check(bank.dueQueue().isEmpty, "after Easy nothing due")
    bank.markKnown(key: "Haus#n")
    check(bank.isKnown("Haus#n"), "mark known without card")
    bank.flush()
    let bank2 = WordBank(language: "de", directory: dir)
    check(bank2.cards.count == 1 && bank2.cards[0].memory.state == .review && bank2.isKnown("Haus#n"), "word bank persists")
    let tsv = DeckExporter.ankiTSV(bank2.cards)
    check(tsv.contains("der Tisch\ttable\tmesa") && tsv.hasPrefix("#separator:tab"), "Anki export format")

    // MARK: Reading room
    section("Reading room")
    let stories = Story.load(language: "de")
    check(stories.count >= 5 && stories.allSatisfy { !$0.title.isEmpty && !$0.level.isEmpty }, "stories load with titles and levels (\(stories.count))")
    let readEngine = LookupEngine(lexicon: lexicon, translator: FakeTranslator(table: [:]))
    if let s = stories.first {
        let doc = ReadingDocument.parse(s.text, engine: readEngine)
        let tokens = doc.flatMap(\.tokens)
        check(doc.count >= 3 && tokens.count > 50, "story parses into paragraphs and words")
        let rebuilt = doc.map { p in p.leading + p.tokens.map { $0.text + $0.trailing }.joined() }
        check(rebuilt == doc.map(\.text), "tokens + trailing text rebuild each paragraph exactly")
        let tagged = tokens.filter { $0.entry != nil }.count
        check(Double(tagged) / Double(max(tokens.count, 1)) > 0.6, "most words of an A1 story are in the pack (\(tagged)/\(tokens.count))")
        if let t = tokens.first(where: { $0.text == "Straßenbahn" }), let p = doc.first(where: { $0.id == t.paragraph }),
           let (sentence, r) = ReadingDocument.sentence(around: t.range, in: p.text) {
            check(String(sentence[r]) == "Straßenbahn" && sentence.hasPrefix("Die Straßenbahn"), "word → its sentence and range")
        }
    }

    // MARK: Tutor helpers
    section("Word diff")
    check(WordDiff.changes("Ich habe gestern nach Berlin gefahren.", "Ich bin gestern nach Berlin gefahren.").map { "\($0.from)>\($0.to)" } == ["habe>bin"], "diff finds habe → bin")
    check(WordDiff.isEquivalent("Er hat mir das Buch gegeben.", "er hat mir das buch gegeben"), "equivalence ignores case/punctuation")
    let blocks = TextBlocks.group([
        RecognizedLine(text: "First line of a paragraph that", rect: CGRect(x: 0.1, y: 0.80, width: 0.5, height: 0.03), confidence: 1, words: []),
        RecognizedLine(text: "continues here.", rect: CGRect(x: 0.1, y: 0.765, width: 0.3, height: 0.03), confidence: 1, words: []),
        RecognizedLine(text: "A separate heading", rect: CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.05), confidence: 1, words: []),
    ])
    check(blocks.count == 2 && blocks[0].text == "First line of a paragraph that continues here.", "groups OCR lines into paragraphs")

    // MARK: Expressions in context (pack phrases)
    section("Expressions in context")
    func expression(_ sentence: String, _ word: String) -> String? {
        let toks = TextTools.analyze(sentence, language: "de")
        guard let t = toks.first(where: { $0.text == word }) else { return nil }
        return lexicon.expressions(in: toks, around: t).first?.lemma
    }
    check(expression("Ich drücke dir die Daumen!", "Daumen") == "Daumen drücken", "Daumen drücken across a split verb (got \(expression("Ich drücke dir die Daumen!", "Daumen") ?? "nil"))")
    check(expression("Er hat sich auf seinen Freund verlassen.", "verlassen") == "sich verlassen auf", "reflexive + preposition: sich verlassen auf")
    check(expression("Er hat das Haus verlassen.", "verlassen") == nil, "plain verlassen is not the reflexive pattern")
    check(expression("Ich verstehe nur Bahnhof.", "Bahnhof") == "Ich verstehe nur Bahnhof", "idiom: Ich verstehe nur Bahnhof")
    check(expression("Wir freuen uns auf den Urlaub.", "freuen") == "sich freuen auf", "uns matches sich: sich freuen auf")
    check(expression("Gibt es hier ein Café?", "Gibt") == "es gibt", "es gibt with inverted order")
    check(expression("Er gibt mir das Buch.", "gibt") == nil, "plain geben is not 'es gibt'")
    check(expression("Ich habe noch nicht gegessen.", "nicht") == "noch nicht", "small-word phrase noch nicht")
    check(expression("Noch habe ich das Buch nicht.", "nicht") == nil, "small-word phrases must be contiguous")
    check(expression("Ich gehe zum Supermarkt, um Brot zu kaufen.", "um") == "um … zu", "split construction um … zu")
    check(expression("Er ging, ohne ein Wort zu sagen.", "ohne") == "ohne … zu", "split construction ohne … zu")

    // MARK: Lookup engine (fake translator)
    section("Lookup engine")
    let fake = FakeTranslator(table: [
        "I put the books on the table.": "Ich lege die Bücher auf den Tisch.",
        "We sat on the river bank all afternoon.": "Wir saßen den ganzen Nachmittag am Ufer des Flusses.",
        "I need to withdraw money from the bank.": "Ich muss Geld von der Bank abheben.",
        "Ich rufe dich morgen an.": "I'll call you tomorrow.",
        "Ich komme mit dem Bus.": "I'm coming by bus.",
        "Die Kinder spielen im Garten.": "The children are playing in the garden.",
    ])
    let engine = LookupEngine(lexicon: lexicon, translator: fake)
    let r1 = await engine.lookup(word: "books", context: "I put the books on the table.")
    check(r1.entry?.lemma == "Buch" && r1.aligned == "Bücher" && r1.headword == "das Buch", "books → das Buch (form Bücher), got \(r1.headword)")
    let r2 = await engine.lookup(word: "bank", context: "I need to withdraw money from the bank.")
    check(r2.entry?.id == "Bank#n", "money bank → Bank (bank), got \(r2.entry?.id ?? "nil")")
    if lexicon.entries(forGerman: "Ufer").isEmpty == false {
        let r3 = await engine.lookup(word: "bank", context: "We sat on the river bank all afternoon.")
        check(r3.entry?.lemma == "Ufer", "river bank → Ufer via context, got \(r3.entry?.lemma ?? "nil")")
    }
    let r4 = await engine.lookup(word: "rufe", context: "Ich rufe dich morgen an.")
    check(r4.entry?.lemma == "anrufen", "separable verb: rufe … an → anrufen, got \(r4.entry?.lemma ?? "nil")")
    let r5 = await engine.lookup(word: "komme", context: "Ich komme mit dem Bus.")
    check(r5.entry?.lemma == "kommen", "'mit dem Bus' doesn't make mitkommen, got \(r5.entry?.lemma ?? "nil")")
    let r6 = await engine.lookup(word: "Kinder", context: "Die Kinder spielen im Garten.")
    check(r6.direction == .fromTarget && r6.entry?.lemma == "Kind" && r6.meanings["en"]?.contains("child") == true, "German word → meaning")
    check(lexicon.bestEntry(forGerman: "Kannst", lemma: "koennen")?.lemma == "können", "umlaut restoration: koennen → können")
    let bd2 = engine.breakdown(of: "Kannst du dich dieses Wochenende um meine Katze kümmern?")
    check(bd2.contains { $0.display == "sich kümmern um" } && !bd2.contains { $0.display == "um" }, "breakdown groups sich kümmern um (got \(bd2.map(\.display)))")
    let bankSenses = engine.senses(ofHelper: "bank", language: "en", translation: "Bank")
    check(Set(bankSenses.map(\.surface)).isSuperset(of: ["Bank", "Ufer"]), "a lone 'bank' lists Bank and Ufer (got \(bankSenses.map(\.display)))")
    let schlossSenses = engine.senses(ofGerman: "Schloss")
    check(schlossSenses.compactMap(\.meaning).contains("lock") && schlossSenses.compactMap(\.meaning).contains("castle"), "Schloss lists lock and castle")
    check(engine.senses(ofHelper: "I would like a coffee please", language: "en", translation: "").isEmpty, "sentences get no sense list")
    let bd = engine.breakdown(of: "Ich lege die Bücher auf den Tisch.")
    check(bd.contains { $0.entry?.lemma == "Buch" } && bd.contains { $0.display == "der Tisch" }, "phrase breakdown finds nouns with articles")

    // MARK: Sprinkles
    section("Sprinkle selector")
    func line(_ text: String, y: CGFloat) -> RecognizedLine {
        // Fake word boxes: each word 60 pt wide on a 1000×800 frame.
        var words: [RecognizedWord] = []
        var x: CGFloat = 0.02
        for r in TextTools.wordRanges(in: text) {
            let w = CGFloat(text[r].count) * 0.008
            words.append(RecognizedWord(text: String(text[r]), rect: CGRect(x: x, y: y, width: w, height: 0.02), range: r))
            x += w + 0.01
        }
        return RecognizedLine(text: text, rect: CGRect(x: 0.02, y: y, width: x, height: 0.02), confidence: 0.9, words: words)
    }
    let lines = [
        line("I put the books on the table before dinner tonight.", y: 0.8),
        line("My brother bought a new car and a red bicycle last week.", y: 0.6),
        line("Die Kinder spielen im Garten mit dem Hund.", y: 0.4),
    ]
    let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    var config = SprinkleConfig()
    config.knownLevels = []
    let ranked = SprinkleSelector.rank(lines: lines, frame: frame, engine: engine, config: config, learner: LearnerSnapshot())
    check(!ranked.isEmpty, "ranks candidates")
    check(!ranked.contains { ["the", "on", "a", "my"].contains($0.word.lowercased()) }, "no stopwords")
    check(ranked.contains { $0.mode == .assist }, "German lines produce assist glosses")
    let picked = await SprinkleSelector.pick(ranked, config: config)
    check(picked.count <= config.budget, "respects budget")
    var perLineCounts: [String: Int] = [:]
    for p in picked { perLineCounts[p.lineText, default: 0] += 1 }
    check(perLineCounts.values.allSatisfy { $0 <= config.maxPerLine }, "max one label per line")
    let knownAll = LearnerSnapshot(knownKeys: Set(ranked.map(\.entry.id)))
    check(SprinkleSelector.rank(lines: lines, frame: frame, engine: engine, config: config, learner: knownAll).isEmpty, "known words are never sprinkled")
    let due = ranked.last!
    let reinforced = SprinkleSelector.rank(lines: lines, frame: frame, engine: engine, config: config,
                                           learner: LearnerSnapshot(reinforcement: [due.entry.id: 1.0]))
    check(reinforced.first?.entry.id == due.entry.id, "due cards come first")
    let again = SprinkleSelector.rank(lines: lines, frame: frame, engine: engine, config: config, learner: LearnerSnapshot())
    check(again.map(\.id) == ranked.map(\.id), "ranking is deterministic")
    var a1Known = config
    a1Known.knownLevels = ["A1"]
    a1Known.nextLevel = "A2"
    let fromA1 = SprinkleSelector.rank(lines: lines, frame: frame, engine: engine, config: a1Known, learner: LearnerSnapshot())
    check(!fromA1.contains { $0.entry.cefr == "A1" }, "placement A1 never tags A1 words")
    check(CEFR.known(upTo: "A2") == ["A1", "A2"] && CEFR.next(after: "A2") == "B1" && CEFR.next(after: "none") == "A1", "CEFR helpers")

    // MARK: OCR
    section("OCR (Vision)")
    let image = renderText(["Put the book on the table before dinner.", "Ich möchte einen Kaffee bestellen, bitte."], size: CGSize(width: 1100, height: 220))
    TextRecognizer.warmUp()
    let started = Date()
    let ocr = (try? TextRecognizer.recognize(image)) ?? []
    print("  OCR \(Int(Date().timeIntervalSince(started) * 1000)) ms, \(ocr.count) lines")
    check(ocr.count == 2, "recognises two lines")
    if let first = ocr.first(where: { $0.text.contains("table") }), let w = first.words.first(where: { $0.text == "table" }) {
        check(w.rect.minX > 0.2 && w.rect.maxX < 0.6, "word box for 'table' is in the right place (\(w.rect))")
    } else {
        check(false, "finds the word 'table' with a box")
    }

    section("Word under the mouse (OCR)")
    let para = renderText(["Yesterday we walked along the river and the", "children found a small turtle near the bank."], size: CGSize(width: 1100, height: 220))
    let paraLines = (try? TextRecognizer.recognize(para)) ?? []
    let paraFrame = CGRect(x: 100, y: 200, width: 1100, height: 220)
    if let turtleLine = paraLines.first(where: { $0.text.contains("turtle") }),
       let turtle = turtleLine.words.first(where: { $0.text == "turtle" }) {
        let p = turtle.rect.denormalized(in: paraFrame).center
        let hit = TextHitFinder.hit(in: paraLines, frame: paraFrame, at: p)
        check(hit?.word == "turtle", "finds the word under the point (got \(hit?.word ?? "nil"))")
        check(hit?.context.hasPrefix("Yesterday we walked") == true && hit?.context.hasSuffix("bank.") == true,
              "context joins the wrapped sentence (got \(hit?.context ?? "nil"))")
        if let hit { check(String(hit.context[hit.range]) == "turtle", "range points at the word in the context") }
        let miss = TextHitFinder.hit(in: paraLines, frame: paraFrame, at: CGPoint(x: 1150, y: 210))
        check(miss == nil, "no hit far from any text")
    } else {
        check(false, "OCR found the paragraph")
    }

    section("OCR pieces on one line")
    func piece(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat) -> RecognizedLine {
        var words: [RecognizedWord] = []
        var cx = x
        for r in TextTools.wordRanges(in: text) {
            let ww = CGFloat(text[r].count) * (w / CGFloat(max(text.count, 1)))
            words.append(RecognizedWord(text: String(text[r]), rect: CGRect(x: cx, y: y, width: ww, height: 0.03), range: r))
            cx += ww + 0.004
        }
        return RecognizedLine(text: text, rect: CGRect(x: x, y: y, width: w, height: 0.03), confidence: 1, words: words)
    }
    // "Sorry, I'm running late." and "Can you look after my cat? She gave up" share a line; the sentence continues below.
    let pieces = [
        piece("Can you look after my cat? She gave up", x: 0.42, y: 0.80, w: 0.5),
        piece("smoking last year and turned down the offer.", x: 0.02, y: 0.76, w: 0.6),
        piece("Sorry, I'm running late.", x: 0.02, y: 0.80, w: 0.38),
    ]
    let f = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let gave = pieces[0].words.first { $0.text == "gave" }!.rect.denormalized(in: f).center
    let gaveHit = TextHitFinder.hit(in: pieces, frame: f, at: gave)
    check(gaveHit?.context == "She gave up smoking last year and turned down the offer.", "sentence continues across pieces and lines (got \(gaveHit?.context ?? "nil"))")
    let run = pieces[2].words.first { $0.text == "running" }!.rect.denormalized(in: f).center
    check(TextHitFinder.hit(in: pieces, frame: f, at: run)?.context == "Sorry, I'm running late.", "first piece keeps its own sentence")
    let headed = [
        piece("Bahn kündigt neue Verbindungen an", x: 0.02, y: 0.70, w: 0.45),
        piece("Die Bahn will ab Dezember mehr Züge zwischen Berlin und München", x: 0.02, y: 0.655, w: 0.9),
        piece("fahren lassen. Viele Pendler hoffen auf weniger Verspätungen.", x: 0.02, y: 0.615, w: 0.85),
    ]
    let zuege = headed[1].words.first { $0.text == "Züge" }!.rect.denormalized(in: f).center
    check(TextHitFinder.hit(in: headed, frame: f, at: zuege)?.context == "Die Bahn will ab Dezember mehr Züge zwischen Berlin und München fahren lassen.",
          "a heading above is not glued to the sentence")
    let columns = [piece("Left column text here", x: 0.02, y: 0.5, w: 0.3), piece("Right column far away", x: 0.7, y: 0.5, w: 0.28)]
    check(TextHitFinder.visualLines(columns, aspect: 1000.0 / 600).count == 2, "distant columns are not merged")

    // MARK: Live (on-device Translation)
    if live {
        section("Live: Apple Translation")
        let apple = AppleTranslator()
        let s = await apple.status(from: "en", to: "de")
        print("  en→de status: \(s)")
        if let out = try? await apple.translate("the table", from: "en", to: "de") {
            check(out.lowercased().contains("tisch"), "the table → \(out)")
        } else {
            check(false, "Apple translation works")
        }
        let realEngine = LookupEngine(lexicon: lexicon, translator: apple)
        let r = await realEngine.lookup(word: "bank", context: "We had a picnic on the river bank.")
        let r2 = await realEngine.lookup(word: "running", context: "I am running late for the meeting.")
        print("  running late → \(r2.headword) confirmed=\(r2.confirmedByContext) [\(r2.contextTranslation ?? "-")]")
        let r3 = await realEngine.lookup(word: "light", context: "This bag is very light.")
        check(r3.entry?.lemma == "leicht", "light (weight) → leicht, got \(r3.headword)")
        let r4 = await realEngine.lookup(word: "light", context: "She turned off the light and went to sleep.")
        check(r4.entry?.lemma == "Licht", "light (lamp) → das Licht, got \(r4.headword)")
        let r5 = await realEngine.lookup(word: "chaves", context: "Ontem perdi as chaves do carro no autocarro.")
        print("  chaves → \(r5.headword) [\(r5.contextTranslation ?? "-")]")
        let r6 = await realEngine.lookup(word: "rufe", context: "Ich rufe dich morgen früh an.")
        check(r6.entry?.lemma == "anrufen", "rufe … an → anrufen, got \(r6.headword); here: \(r6.aligned ?? "-")")
        print("  bank (river) → \(r.headword) confirmed=\(r.confirmedByContext)")
        section("Live: context decides the meaning")
        func live(_ word: String, _ sentence: String) async -> LookupResult { await realEngine.lookup(word: word, context: sentence) }
        let bench = await live("Bank", "Ich sitze auf der Bank im Park.")
        check(bench.entry?.id == "Bank#n#2" && bench.meanings["en"]?.hasPrefix("bench") == true, "Bank on a park → bench (got \(bench.entry?.id ?? "-") / \(bench.meanings["en"] ?? "-"))")
        let money = await live("Bank", "Ich bringe das Geld zur Bank.")
        check(money.entry?.id == "Bank#n", "Bank with money → bank (got \(money.entry?.id ?? "-"))")
        let lock = await live("Schloss", "Das Schloss an der Tür ist kaputt.")
        let castle = await live("Schloss", "Wir besuchen morgen das Schloss.")
        print("  Schloss: \(lock.meanings["en"] ?? "-") | \(castle.meanings["en"] ?? "-")")
        check(lock.meanings["en"]?.hasPrefix("lock") == true && castle.meanings["en"]?.hasPrefix("castle") == true, "Schloss → lock vs castle by context")
        check(lock.senseHere == "lock", "senseHere shows the meaning used (got \(lock.senseHere ?? "nil"))")
        let thumbs = await live("Daumen", "Ich drücke dir die Daumen!")
        check(thumbs.entry?.gender == .masculine, "unknown noun gets its article from a back-translation (Daumen → der, got \(thumbs.headword))")
        check(thumbs.expression?.german == "Daumen drücken", "Daumen → expression Daumen drücken (got \(thumbs.expression?.german ?? "nil"))")
        let rely = await live("verlassen", "Er hat sich auf seinen Freund verlassen.")
        check(rely.expression?.german == "sich verlassen auf", "verlassen + sich + auf → sich verlassen auf")
        let gaveUp = await live("gave", "She gave up smoking last year.")
        print("  gave up → \(gaveUp.headword) · \(gaveUp.expression.map { "\($0.source) → \($0.german)" } ?? "-")")
        check(gaveUp.entry?.lemma == "aufhören" || gaveUp.entry?.lemma == "aufgeben", "gave up → aufhören/aufgeben, not haben (got \(gaveUp.headword))")
        let late = await live("running", "I am running late for the meeting.")
        print("  running late → \(late.headword) · \(late.expression.map { "\($0.source) → \($0.german)" } ?? "-")")
        check(late.expression?.german.contains("spät") == true && late.expression?.german.contains("treffen") == false,
              "running late → expression with spät, never 'treffen' from the noun Treffen")
        let luck = await live("luck", "Good luck with your exam tomorrow!")
        check(luck.expression?.german == "viel Glück", "good luck → viel Glück (got \(luck.expression?.german ?? "nil"))")
        let relied = await live("relied", "He relied on his friend.")
        check(relied.expression?.german == "sich verlassen auf", "relied on → sich verlassen auf (got \(relied.expression?.german ?? "nil"))")
        let turned = await live("turned", "He turned down the offer.")
        print("  turned down → \(turned.headword) · \(turned.expression.map { "\($0.source) → \($0.german)" } ?? "-")")
        check(turned.entry?.lemma == "ablehnen", "turned down → ablehnen (got \(turned.headword))")
        let after = await live("look", "Can you look after my cat this weekend?")
        print("  look after → \(after.headword) · \(after.expression.map { "\($0.source) → \($0.german)" } ?? "-")")
        let lightW = await live("light", "This bag is very light.")
        check(lightW.expression == nil, "a plain word gets no expression")

        let p = try? await realEngine.translatePhrase("Eu gostaria de pedir um café, por favor.")
        print("  PT phrase → \(p?.output ?? "nil") · breakdown: \(p?.breakdown.map(\.display) ?? [])")
        check(p?.inputLanguage == "pt" && p?.outputLanguage == "de", "Portuguese phrase translated into German")

        section("Live: sprinkles end to end")
        let page = renderText([
            "Last weekend my brother and I took the train to the coast.",
            "We left our bags at the hotel and walked along the beach.",
            "In the evening we ate fresh fish in a small restaurant.",
            "Die Kinder spielten im Garten, während die Eltern kochten.",
        ], size: CGSize(width: 1400, height: 380))
        let pageLines = (try? TextRecognizer.recognize(page)) ?? []
        var cfg = SprinkleConfig()
        cfg.knownLevels = ["A1"]
        cfg.nextLevel = "A2"
        let pageFrame = CGRect(x: 0, y: 0, width: 1400, height: 380)
        let ranked = SprinkleSelector.rank(lines: pageLines, frame: pageFrame, engine: realEngine, config: cfg, learner: LearnerSnapshot())
        let started = Date()
        let picked = await SprinkleSelector.pick(ranked, config: cfg, verify: SprinkleSelector.verifier(engine: realEngine))
        print("  \(ranked.count) candidates → \(picked.count) tags in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        for p in picked { print("    \(p.word) → \(p.label) [\(p.mode.rawValue), \(p.reason.rawValue), above \(Int(p.spaceAbove))pt]") }
        check(!picked.isEmpty && picked.count <= cfg.budget, "end-to-end sprinkles produce a budgeted set of tags")
        check(!picked.contains { $0.entry.cefr == "A1" }, "no A1 tags for an A1 learner")

        section("Live: on-device tutor")
        if OnDeviceTutor.isAvailable {
            let tutor = OnDeviceTutor()
            let wrong = "Ich habe gestern nach Berlin gefahren."
            if let fixed = try? await tutor.proofread(german: wrong) {
                print("    \(wrong) → \(fixed)")
                check(fixed.contains("bin"), "tutor corrects haben→sein with fahren")
                if let why = try? await tutor.explainCorrection(original: wrong, corrected: fixed, explainIn: "en") {
                    print(why.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
                }
            }
            let ok = "Er hat mir das Buch gegeben."
            if let same = try? await tutor.proofread(german: ok) {
                check(WordDiff.isEquivalent(ok, same), "tutor leaves a correct sentence alone (got \(same))")
            }
        } else {
            print("  (skipped: \(OnDeviceTutor.availabilityDescription ?? ""))")
        }
    }
}

func renderText(_ lines: [String], size: CGSize) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(origin: .zero, size: size))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    for (i, l) in lines.enumerated() {
        (l as NSString).draw(at: NSPoint(x: 30, y: size.height - 80 - CGFloat(i) * 70),
                             withAttributes: [.font: NSFont.systemFont(ofSize: 34), .foregroundColor: NSColor.black])
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

let task = Task { @MainActor in
    await run()
    print("\n\(passed) passed, \(failed.count) failed")
    if !failed.isEmpty {
        for f in failed { print("  ✗ \(f)") }
        exit(1)
    }
    exit(0)
}
RunLoop.main.run()
