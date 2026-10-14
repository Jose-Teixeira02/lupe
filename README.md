# Lupe: German, everywhere you look

Lupe (German for *magnifying glass*) is a macOS menu-bar companion that turns what you already read
into German practice. It works without changing any app or system language, and everything runs
on your Mac.

| | What it does | Shortcut |
|---|---|---|
| **Ask bar** | Type English or Portuguese and get German. Every word is broken down and coloured by gender. Type German and get its meaning plus a grammar check. | `⌃⌥D` |
| **Hover lens** | Hold `⌃` and rest the mouse on any word in any app. A card shows the German word with *der/die/das*, the plural or verb forms, and the whole sentence translated with the matching word highlighted. | hold `⌃` |
| **Sprinkles** | A small budget of German tags over English or Portuguese words on screen, picked from what you're learning. Over German text, tags show meanings for the hard words instead. | `⌃⌥I` |
| **Lens** | Translates every block of text on the screen in place. Hover a block to listen, copy or save it. | `⌃⌥L` |
| **Selection** | Translates the selected text. Without the Accessibility permission, use right-click → Services → *Translate with Lupe* instead. | `⌃⌥S` |
| **Reading room** | Graded stories (A1–B1, plus one in English and one in Portuguese) or any text you paste. Click a word to see what it means in that sentence. Nouns are coloured by gender and your words are underlined. Works with no permissions. | Journey → Read |
| **Journey** | Daily review with spaced repetition (FSRS), streaks, your words with the sentences you met them in, and your CEFR path. | `⌃⌥J` |

Every word you look up becomes a card with **your sentence** and **the app you met it in**. Reviews
bring it back just before you'd forget it.

## Quick start

```bash
cd "Lupe"
scripts/build-app.sh --install
```

This builds `Lupe.app`, copies it to `~/Applications` and launches it. Look for the magnifier in the
menu bar. The first launch shows a short tour where you pick your languages and level.

You need macOS 26 or later and the Command Line Tools (Xcode isn't required). The German↔English and
German↔Portuguese translation packs are already installed on this Mac.

**Tip:** for a more natural pronunciation, download an *Enhanced* or *Premium* German voice in System
Settings → Accessibility → Spoken Content → System Voice → Manage Voices. Lupe picks the best one
installed automatically.

### Permissions (both optional)

| Permission | Used for | Without it |
|---|---|---|
| **Screen Recording** | Reading words under the mouse in *any* app (PDFs, images, videos), Sprinkles and Lens | The Ask bar, Journey and the Services menu still work |
| **Accessibility** | Exact text in native apps (Safari, Mail, Notes) and `⌃⌥S` | Hover falls back to reading the screen (OCR) |

Lupe never turns these on itself. The menu and Settings have buttons that open the right System
Settings pane. macOS asks again every few weeks whether apps may keep recording the screen; that's
normal.

> **Permissions and rebuilds.** There's no Apple developer certificate on this Mac, so the app is
> signed ad hoc with a fixed identity (`identifier "local.lupe.Lupe"`). That lets permissions survive
> rebuilds. The trade-off: another local program signed with the same identifier would match those
> grants too. A certificate (below) binds them to your own key. If macOS ever stops honouring them
> after an update, toggle Lupe off and on in System Settings → Privacy & Security. To use a real certificate instead: Keychain Access → Certificate
> Assistant → Create a Certificate…, name it **Lupe Dev**, type **Code Signing**. `build-app.sh` picks
> it up automatically.

## Privacy

- Text recognition (Vision), translation (Apple Translation), speech, and the default AI notes
  (Apple Intelligence) all run **on this Mac**. Screenshots are never stored or uploaded.
- Optional: Settings → *AI explanations* → **Claude** uses your own Anthropic API key, stored in the
  Keychain. When it's on, only the sentence you ask about is sent, and only when you press
  *Explain* or `⌘K`.
- Password managers are excluded from reading by default. You can add more apps in Settings.
- Your deck lives in `~/Library/Application Support/Lupe/de/` as plain JSON (`cards.json`,
  `journey.json`). You can export it for Anki from Journey → Words → Export.

## Context decides the meaning

The same word means different things in different sentences, so Lupe always looks at the whole sentence:

| You point at | In this sentence | Lupe shows |
|---|---|---|
| *Bank* | Ich sitze auf der **Bank** im Park. | die Bank, here: **bench** |
| *Bank* | Ich bringe das Geld zur **Bank**. | die Bank, here: **bank** |
| *Schloss* | Das **Schloss** an der Tür ist kaputt. | das Schloss, here: **lock** (castle comes second) |
| *Daumen* | Ich drücke dir die **Daumen**! | expression **Daumen drücken**: to keep one's fingers crossed |
| *verlassen* | Er hat sich auf seinen Freund **verlassen**. | expression **sich verlassen auf**: to rely on |
| *bank* | We had a picnic on the river **bank**. | **das Ufer** (from *Flussufer*), not die Bank |
| *gave* | She **gave** up smoking. | **aufhören** / **aufgeben**, not *geben* or the auxiliary *hat* |
| *running* | I'm **running** late. | expression **zu spät kommen** |
| *light* | This bag is very **light**. | **leicht** (but **das Licht** for a lamp) |

When you type a single word in the Ask bar without a sentence, it lists the possible meanings instead
of guessing: "bank" gives *die Bank* (money) and *das Ufer* (river). A lone word gives the translator
nothing to go on (it turns "nice" into *Netz*), so for single words the dictionary has the last say.

## Don't mix up

Some words are easy to confuse, so cards and the Ask bar put them side by side, each with a note on
when to use it:

| You look up | Lupe adds |
|---|---|
| *schön* | **schön**: beautiful, nice to look at or to experience · **nett**: nice as in kind, friendly · **hübsch**: pretty |
| *gift* | **das Geschenk**: a present · **das Gift**: poison, NOT a gift! |
| *kind* | **nett**: nice, kind · **das Kind**: a child |
| *bekommen* | **bekommen**: to get, NOT to become · **werden**: to become |
| *der See* | **der See**: a lake · **die See**: the sea (formal) · **das Meer**: the sea |

The notes are in `packs/de/confusables.txt`, one group per line, in English and Portuguese. About
55 groups so far: classic pairs (kennen/wissen, legen/stellen, wann/wenn/als) and false friends
(also, bald, Chef, eventuell, Handy, Rente). Words that aren't in a group get a "Similar meaning" box
instead, with other words that share a meaning.

## How it decides what to show

- **Which word you mean.** In "river **bank**", Lupe translates the whole sentence and marks the word
  you hovered. Apple's translation engine reports which German word corresponds to it ("am
  *Flussufer*"). Lupe then matches that word to its German pack, compound nouns included, and shows
  *das Ufer*. If the dictionary sense doesn't appear in the sentence, the card says so instead of
  guessing.
- **Gender and forms** come from a hand-written lexicon of about 2,000 core words with English and
  Portuguese (Portugal) glosses. For words it doesn't list, a compound's last part decides the
  gender: *die Haustür* gets it from *die Tür*.
- **What to sprinkle.** Words that are due for review come first. Next come the most frequent words at
  the level you're working towards. Words you know never get a tag. There's at most one tag per line,
  a few per screen, and tags hide while you scroll.
- **Checking your German.** The AI proposes a corrected sentence and Lupe shows the exact word-level
  changes. "Looks correct" comes from comparing the two sentences, not from the model's opinion.

## Honest limitations

- **OCR misreads very small or stylised text.** In native apps, the Accessibility permission gives
  exact text instead.
- **Machine translation isn't perfect.** I've seen it write "haben … gefahren" where it should be
  "sind". Treat translations as strong hints, not gospel.
- **The on-device AI is a better proofreader than explainer.** Its explanations are labelled as AI notes
  and trimmed to the actual changes. Claude is the better choice if explanations matter to you.
- **The lexicon covers the core vocabulary.** Words outside it still get translations and compound
  genders, but no hand-checked forms.
- **The vocabulary size on the Path is an estimate:** the words of your starting level plus every word
  you've proven since.

## Adding a language (Norwegian is next 🇳🇴)

A language is a pack: a `pack.json` (name, flag, articles, speech voice) and `*.tsv` files with one
word per line:

```
lemma|pos|gender|forms|english glosses|portuguese glosses|CEFR
Tisch|n|m|Tische|table|mesa|A1
fahren|v|-|fährt · fuhr · ist gefahren|to drive; to go (by vehicle)|conduzir; ir (de transporte)|A1
```

An optional `confusables.txt` adds "Don't mix up" notes:

```
words | English notes | Portuguese notes
lernen, studieren | lernen: to learn, to study (any level) ; studieren: to study at university | lernen: aprender ; studieren: estudar na universidade
```

Put the folder in `packs/<code>/`, or in `~/Library/Application Support/Lupe/packs/<code>/` for a
pack you don't want to rebuild for, then pick it under Settings → Languages. Translation works for
any pair macOS supports, Norwegian Bokmål included.

## Development

```bash
scripts/check.sh            # self-check suite (lexicon, FSRS, journey, lookup, sprinkles, OCR)
scripts/check.sh --live     # also exercises on-device Translation and Apple Intelligence
scripts/build-app.sh        # build ./build/Lupe.app (add --debug for a faster debug build)
scripts/build-app.sh --install   # move it to ~/Applications and relaunch (only one Lupe runs at a time)
.build/out/Products/Debug/Lupe --snapshot /tmp/lupe-shots   # render every screen to PNGs
```

| Folder | Contents |
|---|---|
| `Sources/LupeCore` | Testable engine: lexicon packs, text tools, aligned translation, OCR and hit-finding, the lookup engine, sprinkle selection, FSRS, word bank, journey, tutors |
| `Sources/Lupe` | The app: menu bar, global shortcuts (Carbon), ScreenCaptureKit capture, Accessibility reader, hover card, Ask bar, Sprinkles overlay, Lens, Journey window, onboarding |
| `Sources/LupeChecks` | Self-check runner (`swift test` needs full Xcode) |
| `Sources/LupeDebug` | Runs the hover pipeline (OCR → word → context lookup → sprinkles) on any screenshot: `swift run LupeDebug shot.png word1 word2` |
| `packs/de` | The German lexicon (core words, idioms, verb + preposition patterns) and `stories/` for the Reading room |
| `docs/` | `ADR-001`, the architecture decision record and the reasoning behind this design |

The build uses only the Command Line Tools. Because of that, the SwiftUI views use observable
objects instead of `@State`, since the `@State` macro plugin ships only with Xcode.

## Roadmap

- Browser-extension companion (exact DOM text, inline word swaps) that talks to the same deck
- Norwegian pack
- Subtitle mode for videos (watch a region, tag the current line)
- iPhone review over iCloud
- Developer ID signing so permissions survive updates
