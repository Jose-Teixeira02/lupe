import AppKit
import LupeCore
import SwiftUI

/// Renders the main screens with realistic data into PNGs (`Lupe --snapshot <dir>`), using a throwaway
/// data folder and defaults so your real deck is never touched.
@MainActor
enum Snapshots {
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("lupe-snapshot-\(UUID().uuidString)")
        setenv("LUPE_HOME", home.path, 1)
        let defaults = UserDefaults(suiteName: "lupe.snapshot.\(UUID().uuidString)")!
        let settings = LupeSettings(defaults: defaults)
        settings.hasOnboarded = true
        settings.placementLevel = "A1"
        settings.primaryHelper = "en"
        let model = AppModel(settings: settings)
        seed(model)

        // Hover cards with real on-device translation.
        let englishCard = wait { await model.engine.lookup(word: "books", context: "Put the books on the table before dinner, please.") }
        let lightCard = wait { await model.engine.lookup(word: "light", context: "This bag is surprisingly light.") }
        let germanCard = wait { await model.engine.lookup(word: "rufe", context: "Ich rufe dich morgen früh an.") }
        let riverCard = wait { await model.engine.lookup(word: "bank", context: "We had a picnic on the river bank.") }
        let compound = wait { await model.engine.lookup(word: "Haustür", context: "Kannst du bitte die Haustür abschließen?") }
        let lateCard = wait { await model.engine.lookup(word: "running", context: "Sorry, I'm running late for the meeting.") }
        let thumbsCard = wait { await model.engine.lookup(word: "Daumen", context: "Ich drücke dir morgen die Daumen!") }
        let lockCard = wait { await model.engine.lookup(word: "Schloss", context: "Das Schloss an der Tür ist kaputt.") }
        let gaveCard = wait { await model.engine.lookup(word: "gave", context: "She gave up smoking last year.") }
        let schoenCard = wait { await model.engine.lookup(word: "schön", context: "Das Wetter ist schön, die Sonne scheint.") }
        let niceCard = wait { await model.engine.lookup(word: "nice", context: "Your brother is really nice to everyone.") }
        let giftCard = wait { await model.engine.lookup(word: "gift", context: "Thank you for the lovely gift!") }
        for (name, r, saved) in [("card-en-books", englishCard, true), ("card-en-light", lightCard, false),
                                 ("card-de-anrufen", germanCard, true), ("card-en-riverbank", riverCard, false),
                                 ("card-de-compound", compound, true), ("card-en-runninglate", lateCard, true),
                                 ("card-de-daumen", thumbsCard, true), ("card-de-schloss", lockCard, true),
                                 ("card-en-gaveup", gaveCard, true), ("card-de-schoen", schoenCard, true),
                                 ("card-en-nice", niceCard, true), ("card-en-gift", giftCard, true)] {
            let s = LookupCardState()
            s.reset(.ready(r))
            if saved { s.saved = .saved(UUID(), created: true) }
            save(LookupCardView(state: s, lexicon: model.lexicon, helpers: settings.helpers, actions: .init()), dir, name)
            save(LookupCardView(state: s, lexicon: model.lexicon, helpers: settings.helpers, actions: .init()), dir, name + "-dark", dark: true)
        }
        let hint = LookupCardState()
        hint.reset(.hint(title: "Lupe can't read this text yet", message: "Allow Screen Recording so Lupe can read words under the mouse in any app. Everything stays on your Mac.", action: "Open Screen Recording settings"))
        save(LookupCardView(state: hint, lexicon: model.lexicon, helpers: settings.helpers, actions: .init()), dir, "card-hint")

        // Ask bar: EN → DE and a German check.
        let ask = AskState()
        ask.input = "I'm running late, sorry!"
        ask.result = wait { try? await model.engine.translatePhrase("I'm running late, sorry!") }
        save(AskView(state: ask, model: model, actions: .init()), dir, "ask-en")
        for word in ["nice", "kind", "gift"] {
            let single = AskState()
            single.input = word
            single.result = wait { try? await model.engine.translatePhrase(word) }
            save(AskView(state: single, model: model, actions: .init()), dir, "ask-en-\(word)")
        }
        let check = AskState()
        check.input = "Ich habe gestern nach Berlin gefahren."
        check.result = wait { try? await model.engine.translatePhrase(check.input) }
        if let fixed = wait({ try? await model.tutor.proofread(german: check.input) }) {
            check.corrected = fixed
            check.diff = WordDiff.diff(check.input, fixed)
        }
        save(AskView(state: check, model: model, actions: .init()), dir, "ask-de-check")
        save(AskView(state: check, model: model, actions: .init()), dir, "ask-de-check-dark", dark: true)
        let empty = AskState()
        model.rememberAsk("How do I say I'm running late?")
        model.rememberAsk("Wie spät ist es?")
        save(AskView(state: empty, model: model, actions: .init()), dir, "ask-empty")

        // Menu and Journey sections.
        save(MenuView(model: model, actions: .init()), dir, "menu")
        save(MenuView(model: model, actions: .init()), dir, "menu-dark", dark: true)
        let size = CGSize(width: 1020, height: 680)
        save(TodayView(model: model, openSection: { _ in }, openAsk: {}), dir, "today", size: size)
        save(PathView(model: model), dir, "path", size: size)
        let words = WordsState()
        words.selected = model.bank.cards.first?.id
        save(WordsView(model: model, state: words), dir, "words", size: size)
        let session = ReviewSession(model: model)
        session.start()
        save(ReviewView(session: session, model: model), dir, "review-front", size: size)
        session.reveal()
        save(ReviewView(session: session, model: model), dir, "review-back", size: size)
        save(ReviewView(session: session, model: model), dir, "review-back-dark", size: size, dark: true)
        save(SettingsView(model: model, settings: settings, permissions: model.permissions, reminderChanged: {}), dir, "settings", size: CGSize(width: 760, height: 1500))
        save(HelpView(), dir, "help", size: size)
        let reading = ReadingState(model: model)
        reading.loadStories()
        if let story = reading.stories.first(where: { $0.level == "B1" }) { reading.open(story) }
        if let t = reading.paragraphs.flatMap(\.tokens).first(where: { $0.text == "Bahnhof" }) {
            reading.select(t)
            _ = wait { try? await Task.sleep(for: .seconds(3)); return true }
        }
        save(ReadingView(state: reading, model: model), dir, "reading", size: CGSize(width: 1100, height: 760))

        // Onboarding pages.
        let ob = OnboardingState()
        for p in 0..<ob.pages {
            ob.page = p
            save(OnboardingView(state: ob, model: model, settings: settings, permissions: model.permissions, tryAsk: {}, finish: {}), dir, "onboarding-\(p)")
        }

        // Sprinkles on a fake page.
        save(SprinkleDemo(), dir, "sprinkles", size: CGSize(width: 760, height: 300))
        save(SprinkleDemo(), dir, "sprinkles-dark", size: CGSize(width: 760, height: 300), dark: true)
        save(AppMark(size: 256), dir, "appmark", size: CGSize(width: 256, height: 256))
        print("Snapshots written to \(dir.path)")
    }

    /// The app icon: the mark on a transparent canvas with macOS's standard margins (824 px tile in 1024).
    static func renderIcon(to url: URL) {
        let view = AppMark(size: 824).padding(100).frame(width: 1024, height: 1024)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        // cacheDisplay renders at the backing scale; resample to exactly 1024×1024.
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        rep.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Runs async work while spinning the main run loop (snapshot mode only).
    static func wait<T>(_ work: @escaping @MainActor () async -> T) -> T {
        var result: T?
        Task { @MainActor in result = await work() }
        // No deadline: Vision/Translation warm-up can take minutes on a cold Mac.
        while result == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return result!
    }

    static func seed(_ model: AppModel) {
        let lex = model.lexicon
        let samples: [(String, String, String, String?)] = [
            ("Buch", "Put the books on the table before dinner.", "Stell die Bücher vor dem Abendessen auf den Tisch.", "Bücher"),
            ("Schlüssel", "I lost my keys at the station.", "Ich habe meine Schlüssel am Bahnhof verloren.", "Schlüssel"),
            ("anrufen", "Ich rufe dich morgen an.", "I'll call you tomorrow.", "rufe"),
            ("Fenster", "Could you close the window?", "Könntest du das Fenster schließen?", "Fenster"),
            ("leicht", "This bag is very light.", "Diese Tasche ist sehr leicht.", "leicht"),
            ("Wohnung", "Our new flat has a big kitchen.", "Unsere neue Wohnung hat eine große Küche.", "Wohnung"),
            ("vergessen", "Don't forget your umbrella!", "Vergiss deinen Regenschirm nicht!", "Vergiss"),
            ("Zeitung", "Ele lê o jornal todas as manhãs.", "Er liest jeden Morgen die Zeitung.", "Zeitung"),
        ]
        let apps = ["Safari", "Discord", "WhatsApp", "Notes", "Safari", "Mail", "Safari", "Safari"]
        for (i, (lemma, sentence, translation, form)) in samples.enumerated() {
            guard let e = lex.entries(forGerman: lemma).first else { continue }
            let lang = TextTools.detectLanguage(sentence, candidates: ["en", "pt", "de"]) ?? "en"
            var meanings: [String: String] = [:]
            for h in ["en", "pt"] { if let g = e.gloss(h) { meanings[h] = g } }
            let enc = Encounter(sentence: sentence, translation: translation, language: lang, app: apps[i],
                                date: Date().addingTimeInterval(-Double(i) * 3600 * 5), targetForm: form)
            let (card, _) = model.bank.add(term: e.lemma, entry: e, display: lex.display(e), meanings: meanings, encounter: enc, source: .hover)
            if i % 3 == 1 { model.bank.review(card.id, rating: .good, now: Date().addingTimeInterval(-86_400 * 6)) }
        }
        model.savePhrase(german: "Ich komme etwas später.", meaning: "I'm running a bit late.", meaningLanguage: "en", source: .ask)
        let j = model.journey
        let cal = Calendar.current
        for d in 1...40 where d % 7 != 3 {
            j.clock = { cal.date(byAdding: .day, value: -d, to: Date())! }
            for _ in 0..<(8 + (d * 7) % 25) { j.record(.review(.good)) }
        }
        j.clock = { Date() }
        for _ in 0..<9 { j.record(.lookup) }
        for _ in 0..<6 { j.record(.review(.good)) }
    }

    static func save<V: View>(_ view: V, _ dir: URL, _ name: String, size: CGSize? = nil, dark: Bool = false) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = appearance
        let fitting = size ?? host.fittingSize
        host.frame = CGRect(origin: .zero, size: fitting)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.95, alpha: 1)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        // Composite on the window background so translucent materials stay readable.
        let out = NSImage(size: host.bounds.size)
        out.lockFocus()
        window.backgroundColor.setFill()
        NSRect(origin: .zero, size: host.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: host.bounds.size))
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff), let png = bmp.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent(name + ".png"))
        }
    }
}

/// A fake web page with sprinkle tags, for the design snapshot.
struct SprinkleDemo: View {
    var body: some View {
        let state = SprinkleOverlayState()
        let text = "Before dinner, my brother put the books on the kitchen table and opened the window."
        ZStack(alignment: .topLeading) {
            Color(nsColor: .textBackgroundColor)
            VStack(alignment: .leading, spacing: 10) {
                Text("Weekend plans").font(.system(size: 22, weight: .bold))
                Text(text).font(.system(size: 16)).lineSpacing(9)
                Text("Die Kinder spielen im Garten, während die Eltern das Abendessen vorbereiten.").font(.system(size: 16)).lineSpacing(9)
            }
            .padding(30)
            SprinkleOverlayView(state: state)
        }
        .onAppear {
            state.labels = [
                SprinkleLabel(id: "1", text: "der Bruder", gloss: "brother", gender: .masculine, pos: .noun,
                              wordRect: CGRect(x: 157, y: 71, width: 58, height: 19), mode: .teach, darkBackground: false),
                SprinkleLabel(id: "2", text: "das Buch", gloss: "book", gender: .neuter, pos: .noun,
                              wordRect: CGRect(x: 279, y: 71, width: 44, height: 19), mode: .teach, darkBackground: false),
                SprinkleLabel(id: "3", text: "das Fenster", gloss: "window", gender: .neuter, pos: .noun,
                              wordRect: CGRect(x: 30, y: 99, width: 56, height: 19), mode: .teach, darkBackground: false),
                SprinkleLabel(id: "4", text: "to prepare", gloss: "vorbereiten", gender: nil, pos: .verb,
                              wordRect: CGRect(x: 30, y: 155, width: 94, height: 19), mode: .assist, darkBackground: false),
            ]
            state.expanded = "2"
        }
    }
}
