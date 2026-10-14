import AppKit
import Foundation
import LupeCore

// Dev tool: runs Lupe's hover pipeline (OCR → word under point → context lookup) on a screenshot.
// Usage: LupeDebug <image> word1 word2 ...
//        LupeDebug --ask "nice" "kind" ...   (the Ask bar's answer for each input)
let args = CommandLine.arguments
if args.count >= 3, args[1] == "--ask" {
    let lex = try! LupePaths.loadLexicon("de")
    let engine = LookupEngine(lexicon: lex, translator: AppleTranslator(), helpers: ["en", "pt"], primaryHelper: "en")
    let done = DispatchSemaphore(value: 0)
    Task {
        for input in args.dropFirst(2) {
            guard let r = try? await engine.translatePhrase(input) else { print("✗ \(input): failed"); continue }
            print("• \(input) [\(r.inputLanguage)] → \(r.output)   senses: \(r.senses.map(\.surface).joined(separator: ", "))")
        }
        done.signal()
    }
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    exit(0)
}
guard args.count >= 2, let ns = NSImage(contentsOfFile: args[1]), let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: LupeDebug <image> words…"); exit(1)
}
let words = Array(args.dropFirst(2))
let frame = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
let lex = try! LupePaths.loadLexicon("de")
let engine = LookupEngine(lexicon: lex, translator: AppleTranslator(), helpers: ["en", "pt"], primaryHelper: "en")
let done = DispatchSemaphore(value: 0)
Task {
    TextRecognizer.warmUp()
    let lines = (try? TextRecognizer.recognize(cg)) ?? []
    print("OCR \(lines.count) lines")
    for v in TextHitFinder.visualLines(lines, aspect: frame.width / frame.height) {
        print(String(format: "  | h=%.4f y=%.3f  ", v.rect.height, v.rect.minY) + v.text)
    }
    for w in words {
        guard let line = lines.first(where: { $0.words.contains { $0.text == w } }),
              let ow = line.words.first(where: { $0.text == w }) else { print("✗ \(w): not found by OCR"); continue }
        let p = ow.rect.denormalized(in: frame).center
        guard let hit = TextHitFinder.hit(in: lines, frame: frame, at: p) else { print("✗ \(w): no hit"); continue }
        let t0 = Date()
        let r = await engine.lookup(word: hit.word, context: hit.context, wordRange: hit.range)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        var line1 = "• \(w) [\(r.sourceLanguage)] → \(r.headword)"
        if let s = r.senseHere { line1 += "  here: \(s)" }
        if let ex = r.expression { line1 += "  EXPRESSION: \(ex.source) → \(ex.german) (\(ex.meaning))" }
        if !r.confirmedByContext { line1 += "  (unconfirmed)" }
        print(line1 + "  [\(ms) ms]")
        print("    meanings: \(r.meanings["en"] ?? "-") | \(r.meanings["pt"] ?? "-")")
        print("    context: \(hit.context)")
        print("    → \(r.contextTranslation ?? "-")  aligned: \(r.aligned ?? "-")")
    }
    var cfg = SprinkleConfig(); cfg.knownLevels = ["A1"]; cfg.nextLevel = "A2"; cfg.minWordHeight = 6
    let ranked = SprinkleSelector.rank(lines: lines, frame: frame, engine: engine, config: cfg, learner: LearnerSnapshot())
    let picked = await SprinkleSelector.pick(ranked, config: cfg, verify: SprinkleSelector.verifier(engine: engine))
    print("Sprinkles (A1 learner): " + picked.map { "\($0.word)→\($0.label)" }.joined(separator: ", "))
    done.signal()
}
while done.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
