# ADR-001: An on-screen language companion for macOS ("Lupe")

**Status:** Accepted (v0.1 built in this repo)
**Date:** 2026-10-14
**Deciders:** José Teixeira (creator and product owner), Claude (implementation, via Claude Code)

## Context

The learner is studying German, and later other languages, alongside English and Portuguese. The main
source of friction is switching to a translation site every time they see a phrase they want in German,
or a German phrase they want to understand. The goal:

> A translator that lives on the screen, without changing the app or system language, that
> highlights common words or shows translations **without making the screen a mess**, and turns
> daily exposure into a learning journey.

### Can it be built? Yes. What I measured on the development Mac (macOS 27.0.1, Apple Silicon)

| Capability | API | Measured here |
|---|---|---|
| Offline translation EN/PT ↔ DE | `Translation.TranslationSession(installedSource:target:)` | Language packs **already installed**. 150–200 ms per phrase once warm. Works outside SwiftUI. |
| Read text from screen pixels | Vision `VNRecognizeTextRequest` | Region of 600×120 px: **~45 ms** (accurate) or ~6 ms (fast). Full Retina screen: **~100 ms**. The first call costs ~24 s to load the model, so the app warms it up at launch. |
| Word-level boxes on screen | `VNRecognizedText.boundingBox(for:)` | Works. Lets labels sit exactly on a single word. |
| Lemmas (Kinder→Kind, spielten→spielen, running→run) | `NaturalLanguage.NLTagger(.lemma)` | Works for DE and EN. |
| Grammar explanations with no cloud | `FoundationModels` (Apple Intelligence) | Available, supports de/pt/en. ~2.7 s. **Quality is uneven:** its first explanation of *auf den Tisch* gave the wrong reason. Explanations must be labelled as AI notes. |
| Speech | `AVSpeechSynthesizer` (German voices) | Built in. |

**Consequence:** the whole pipeline (see → read → translate → explain → speak) runs **on the device,
free, offline and private**. Nothing on the screen leaves the Mac. This was the most important
finding, because a tool that streams your screen to a cloud API would be a non-starter.

### Forces

* **Low friction beats features.** Each extra keystroke is a reason to skip learning today.
* **"Don't make the screen a mess."** A full-screen word-by-word overlay would be noisy and would
  hurt both reading and learning. Attention is the scarce resource.
* **Learning, not just translating.** DeepL already translates. What it does not do is remember what
  you looked up, show it to you again where you met it, and space reviews over time.
* **Scalable to more languages.** German now, perhaps Norwegian next. Language-specific data must
  be a pluggable pack, not code.
* **macOS permissions.** Reading pixels needs Screen Recording. Reading text from the accessibility
  tree and reading selections need Accessibility. Since macOS 15, apps using screen capture get a
  periodic "still allow?" prompt. With no Apple developer certificate on this Mac, an ad-hoc signed
  build **loses its permissions on every rebuild**.

## Decision

Build a **native macOS menu-bar app (Swift, AppKit + SwiftUI)** called **Lupe** (German for
magnifying glass). It offers **four interaction layers**, from always-quiet to on-demand. Every layer
feeds **one personal word bank** that uses FSRS spaced repetition.

| Layer | Trigger | What you see | Permission |
|---|---|---|---|
| **1. Ask bar** ("how do I say…?") | `⌃⌥D` from anywhere | Spotlight-style field. Type EN or PT and get German live (or the reverse). Includes a word breakdown with gender colours, 🔊, copy, save, and *Explain*. | **None** |
| **2. Hover lens** | Hold `⌃` and rest the mouse on any word | A small card over the word with the German lemma, gender, plural or verb forms, the line translated in context, and Save / I-know-it / 🔊 / Explain. | Screen Recording (OCR), or Accessibility (precise text) |
| **3. Sprinkles** (immersion) | Toggle `⌃⌥I` | A *budget* of 5–8 tiny gender-coloured German labels over English/Portuguese words on screen. They are chosen from your due words first, then from the next words you should learn. They hide while you scroll. | Screen Recording |
| **4. Lens** (translate screen) | `⌃⌥L`, press Esc to close | A one-shot overlay that translates every visible text block, like Google Lens. | Screen Recording |
| **Selection** | `⌃⌥S`, or the right-click Services menu | Translates the selected text in the Ask bar. | Accessibility (hotkey) / none (Services) |
| **Journey** | Menu bar or `⌃⌥J` | Daily review (FSRS), streak, goal ring, CEFR path, words met today with the sentence where you met them, Anki export. | None |

The Ask bar and Journey work with **zero permissions**, so the app is useful from the first minute,
before any System Settings visit.

### Key design choices inside the decision

1. **Translation engine: Apple on-device Translation, behind a `Translator` protocol.** DeepL or LLM
   providers can be added later without touching the UI.
2. **A curated lexicon pack (`packs/de/lexicon.tsv`) for word-level lookups.** It stores the lemma,
   gender, plural or principal parts, glosses in EN and PT, frequency rank and CEFR level.
   Translating single words by machine loses gender and picks random senses (*Feierabend* →
   "evening"). The pack is instant, so sprinkles cost no translation calls.
3. **Word-aligned translation for sense.** The hovered word is marked inside the sentence and
   translated as an attributed string (macOS 26.4+). The mark survives translation onto the
   corresponding German words: *light* → *Licht* in "turned off the light" but *leicht* in "this bag
   is light". The aligned German word is then matched to the lexicon, compounds included
   (*Flussufer* → *das Ufer*). Sprinkles use the same check and drop a tag if the sense doesn't hold.
4. **Gender colour code:** blue *der*, red *die*, green *das*. This is the classic learner
   convention, and it teaches articles without words.
5. **Auto-capture with context.** Every lookup goes into the word bank together with the sentence
   and the app where you met it. Reviews then show *your* sentence ("you met this in Safari: '…put it
   on the table…'"). That personal link is the strongest memory hook available.
6. **Scheduling: FSRS-4.5** (open, research-backed, better than SM-2), with default weights.
7. **AI as a proofreader, not an oracle.** Measured on this Mac, the on-device model fixed all six
   test sentences when asked *only* for the corrected sentence. Asked to explain or to judge "is
   this correct?", it invented rules. So Lupe asks for the fixed sentence, computes the word diff
   itself (the verdict comes from the diff), and asks for explanations only of the changed words,
   then trims any extra points. A **Claude** provider (`claude-opus-5-5`, your key in the Keychain,
   server-side refusal fallback) is opt-in for better explanations.
8. **Storage:** JSON files in `~/Library/Application Support/Lupe`, behind a store type. A few
   thousand cards is tiny, and the files are human-readable and easy to back up. SQLite can replace
   them later behind the same interface.

## Options Considered

### Option A: Native macOS menu-bar app with Vision OCR and on-device Translation (chosen)

| Dimension | Assessment |
|---|---|
| Complexity | Medium-high (overlays, capture, coordinates, permissions) |
| Cost | Free. No API keys, no subscription. |
| Scalability | New language = new lexicon pack plus an Apple language download |
| Familiarity | Swift/AppKit; builds with the Command Line Tools only (no Xcode needed) |
| Privacy | Excellent. Pixels and text never leave the Mac. |

**Pros:** works in every app (browsers, PDFs, videos with subtitles, games, images). It is instant
and offline, and it sits right where the friction happens.
**Cons:** OCR can misread tiny or stylised text. It needs Screen Recording, which comes with
macOS's periodic re-confirmation prompt. Overlays need careful engineering to stay subtle.

### Option B: Browser extension (DOM-based, like Toucan or Language Reactor)

| Dimension | Assessment |
|---|---|
| Complexity | Low-medium |
| Cost | Free with on-device models; otherwise API costs |
| Scalability | Good for the web only |
| Privacy | Good if local |

**Pros:** exact text, perfect positioning, can replace words inline, no Screen Recording permission.
**Cons:** **only inside the browser.** It misses chat apps, games, PDFs, code editors and system
UI, where a lot of daily reading happens. It is worth doing as a *companion* later, talking to the
same word bank over localhost.

### Option C: Clipboard and hotkey translator only (like DeepL's ⌘C⌘C)

| Dimension | Assessment |
|---|---|
| Complexity | Low |
| Privacy | Depends on the engine |

**Pros:** trivial to build and robust.
**Cons:** it is what a translation website already offers. There is no ambient exposure and no learning
loop, so it removes only part of the friction.

### Option D: Cloud LLM vision on screenshots (send the screen to GPT/Claude)

**Pros:** best understanding of context.
**Cons:** seconds of latency, real cost per screen, and **sends everything on screen to a third
party.** Rejected as the core, but kept as an *opt-in* "Explain" provider for single sentences.

## Trade-off Analysis

* **Coverage vs. precision.** OCR (Option A) covers 100 % of apps with ~95 % precision. The DOM
  (Option B) covers maybe 40 % of screen time with 100 % precision. For *reducing friction*,
  coverage wins. Where Accessibility gives exact text (native apps, Safari), Lupe uses it first and
  falls back to OCR.
* **Ambient vs. on-demand.** Ambient overlays teach passively but can annoy. On-demand is calm but
  needs intent. **Both, with a strict budget:** sprinkles are off by default, capped per screen,
  hidden while scrolling, and never cover more than one word.
* **Curated pack vs. machine translation for words.** The pack gives gender, plural, sense and
  instant speed, but covers only about the top 2–3k lemmas. Machine translation covers everything
  but is slower and loses gender. **Use the pack first and fall back to Translation**, which is fine:
  the top 2k lemmas cover roughly 80 % of running text.
* **On-device AI vs. Claude for explanations.** On-device is free and private but sometimes wrong;
  Claude is excellent but needs a key and sends one sentence over the network. Default on-device,
  label it, and allow an upgrade.

## Would I be pleased with the result? An honest answer

**Yes, if it stays quiet.** The thing I would love is the Ask bar: one keystroke, type "how do I
say I'm running late", see German and hear it, done. The hover card comes a close second. Sprinkles
are the most *magical* layer and the most dangerous one. Too many labels and you turn them off
forever, which is why they are budgeted, coloured by gender and chosen by spaced repetition, not at
random.

What would disappoint me, and is now designed against:

* Translating a single word without its article. **Fixed:** every noun shows *der/die/das* plus plural.
* Lookups that vanish. **Fixed:** every lookup becomes a card with the sentence where you met it.
* Being nagged. **Fixed:** the streak is gentle, there is one optional daily reminder, and nothing
  pops up unless you ask.
* "It doesn't work in app X." This is partly unavoidable: OCR misreads tiny text and some apps block
  capture. The fallback is the Ask bar plus selection.

## Lessons from building it (2026-10-14)

* **Translation model strategy:** binaries linked against an older SDK default to "low latency"
  models, which weren't installed here. Lupe asks for the installed "high fidelity" models
  explicitly.
* **Vision's first call** can take from 24 seconds to several minutes while it loads its model.
  Lupe warms it up in the background at launch.
* **Placement by CEFR, not by rank.** The learning frontier ("words you probably know") uses each
  entry's CEFR level, so everyday words can live in any pack file.
* **Toolchain:** with only the Command Line Tools, SwiftUI's `@State` macro and Swift Testing are
  unavailable. The UI uses observable objects, and a `LupeChecks` executable replaces `swift test`.
* **Capture exclusion:** only Lupe's *floating* windows (tags, cards, lens) are hidden from capture.
  Hiding the Journey window too would let OCR "see through" it.

## Consequences

* **Easier:** daily micro-exposure across *every* app, a personal deck built from real life, adding
  Norwegian by dropping `packs/nb/lexicon.tsv`, and swapping engines (DeepL, Claude) behind protocols.
* **Harder:** permission UX (ad-hoc signing means permissions reset after each rebuild), multi-monitor
  coordinate maths, and keeping the overlay calm across many apps.
* **To revisit:** a browser-extension companion, a Developer ID certificate (stable permissions,
  shareable app), SQLite if the deck grows past ~20k cards, iPhone review via iCloud, and
  subtitle-aware mode for videos.

## Action Items

1. [x] Probe on-device APIs (Translation, Vision, NL, FoundationModels) on the target Mac.
2. [x] Core library: lexicon packs, tokenizer and lemmatizer, translator and cache, FSRS, word bank, sprinkle selector.
3. [x] App: menu bar, hotkeys, Ask bar, hover card, sprinkles, lens, Journey and review, onboarding, settings.
4. [x] German core lexicon pack (gendered nouns, verb principal parts, EN and PT glosses, CEFR).
5. [x] Build script producing `Lupe.app` (ad-hoc signed), plus a self-check suite.
6. [ ] First run: grant Screen Recording and Accessibility, then tune the sprinkle budget.
7. [x] Optional Claude "Explain" and grammar-check provider (opt-in, your own API key).
8. [ ] Later: browser-extension companion, Norwegian pack, subtitle mode, Developer ID signing.
