# Burrow — Roadmap

Status: active
Derived from: [`docs/feature-gap-map.md`](docs/feature-gap-map.md) (2026-11-09)
Scope: Android first; iOS is explicitly out of scope until the Rust engine can
be packaged for it.

## How to read this

This roadmap is organized in **phases, not dates**. A phase ships when its items
meet their "done when" tests, not when a calendar says so.

- **Now** — the next release. Closing the gaps that make readers keep another
  app installed.
- **Next** — the release after. Depth, polish, and reach.
- **Later** — bets worth keeping on the list, not commitments.
- **Not doing** — features that would fight the product's identity.

Each item lists why it matters, the smallest useful shape, and what "done"
means. Items graduate to a design doc in `docs/superpowers/specs/` before
implementation begins.

## Product guardrails

Burrow is a **minimal, fast, local-first e-book reader**. Every item is judged
against three questions:

1. Does it help someone finish a book they are already reading?
2. Can it work offline, with no account?
3. Does it stay out of the way when unused?

If an item fails all three, it belongs in **Not doing**.

---

## Now — close the daily-reading gaps

**Theme:** no daily reading task should force the user into another app.

### 1. Highlights, quotes, and notes

**Why:** the single biggest functional gap. Burrow can select text, but cannot
keep it. Every surveyed competitor can.

**Smallest useful shape:**
- New `Highlights` table: `bookId`, chapter, flat start/end offsets, selected
  text, colour, optional note, `createdAt`.
- Selection toolbar gains **Highlight** and **Note**.
- A Quotes/Notes tab beside TOC and Bookmarks in the reader.
- Tap a highlight to jump back to it; edit or delete from the list.
- Export as Markdown and JSON.

**Done when:** a highlight survives app restart, appears in the book's quote
list, jumps back to the right passage in EPUB, PDF, and TXT, and exports.

**Depends on:** nothing. Start here.

### 2. Local backup and restore

**Why:** Burrow persists the library index, progress, bookmarks, collections,
and stats in SQLite and has no export of any kind. A lost phone loses all of it.
Cloud sync is not required to fix the data-loss problem.

**Smallest useful shape:**
- Export a single archive: database contents as JSON, plus covers and cached
  metadata.
- Import through the file picker with a merge/preview step.
- No account, no network, no background upload.

**Done when:** a clean install can restore a library from the export and reopen
books at their saved positions.

**Depends on:** nothing. Do it before cloud sync is even discussed.

### 3. Read aloud (TTS)

**Why:** expected by mainstream readers and an accessibility win. Four of the
six surveyed competitors have it.

**Smallest useful shape:**
- Android system TTS, no cloud voice.
- Play/pause, speed, pitch, and voice selection in the reader chrome.
- Sentence-level highlight that follows the spoken text.
- Stops cleanly on chapter end or app background.

**Done when:** a user can listen to an EPUB chapter with the screen off and
resume where playback stopped.

### 4. Translate selection

**Why:** the dictionary handles words, not sentences, and "share" is the current
workaround.

**Smallest useful shape:**
- **Translate** action in the selection toolbar.
- Route to installed translator apps through the existing share/intent layer.
- No bundled translation model and no mandatory API key.

**Done when:** selecting a sentence and tapping Translate opens a translator
with the sentence pre-filled.

**Depends on:** nothing. Reuses `SharePlus`/intent plumbing.

### 5. Format expansion: MOBI, AZW3, FB2

**Why:** Kindle and FB2 libraries are common, and every surveyed competitor
except Readest covers at least one of these.

**Smallest useful shape:**
- Add the formats to `BookFormat`, the import filters, the Android intent
  filters, and the Rust parser path.
- Extract title, author, cover, and TOC through the existing metadata pipeline.
- Fail loudly on DRM-protected files instead of importing garbage text.

**Done when:** a MOBI and an FB2 file import, show metadata and a cover, and read
with pagination and TOC.

**Depends on:** parser work in `rust/`; design doc required.

### 6. Custom fonts and continuous scroll

**Why:** two comfort features competitors treat as standard. Burrow ships nine
bundled fonts and paginated reflow only.

**Smallest useful shape:**
- Import `.ttf`/`.otf` through the file picker, store in app support, register
  with `FontLoader`, list alongside bundled fonts.
- Add a scrolling mode for reflowable chapters, reusing the existing
  position/progress machinery.
- Keep pagination as the default.

**Done when:** an imported font survives restart and a user can read an EPUB in
continuous scroll without losing their place when switching modes.

**Depends on:** reader layout work; design doc required.

### Quick wins to land alongside

These are small, visible, and unblock trust in the roadmap:

- Reword the README Smart Groups bullet, or ship rule-based groups (see Next).
- Add an **Export library** entry as soon as item 2 exists.
- Add the onboarding completion page and Settings re-entry from
  `design/onboarding-redesign.md`.
- Bring the README up to date with archive, trash, multi-select, dictionary
  chooser, metadata fetch, missing-file recovery, and comic zoom.

---

## Next — depth, polish, and reach

### 7. Rule-based smart groups

**Why:** the README promises "by rules", but the code has three fixed buckets
(Reading, Finished, New). Either build the rule builder or correct the promise.

**Smallest useful shape:** saved filters over the existing filter fields
(status, format, genre, series, progress), with a name and an optional icon.

**Done when:** a user can create "Unread sci-fi under 300 pages" and see it
persist across restarts.

### 8. Onboarding redesign completion

**Why:** `design/onboarding-redesign.md` describes a flow that is mostly
unbuilt. The current 4-page flow works; the redesign adds personality and
recovery.

**Remaining scope:** typography step, completion page with a summary, Settings
re-entry, sample/free books for empty devices, post-scan cover carousel, and the
analytics events that have no UI to fire from yet.

### 9. Duplicate detection

**Why:** identity is still path-based. Re-importing the same book creates a
duplicate unless the path matches exactly.

**Smallest useful shape:** size + partial content hash on import; surface
potential duplicates and let the user merge or keep both.

### 10. Full-text library search

**Why:** library search currently covers title and author. Large libraries need
content search, which the in-book search engine already makes possible.

**Smallest useful shape:** index chapter text during import; search across the
library with per-book result counts.

### 11. Reading goals and stats export

**Why:** stats are already a differentiator. Goals and export turn them into a
habit and make the data portable.

**Smallest useful shape:** daily/weekly time or page goals, streak continuity,
and CSV/JSON export of the existing session data.

### 12. Localization

**Why:** English-only blocks most non-English markets, and every surveyed
competitor localizes.

**Smallest useful shape:** add `flutter_localizations` and `intl`, extract
strings, ship one non-English locale end to end, and make locale selectable in
Settings.

**Done when:** the full onboarding, library, reader, and settings flows work in
the pilot locale.

### 13. Reader polish

**Why:** the last comfort gap between Burrow and mature readers.

**Scope:** hyphenation, dual-page/landscape for reflowable text, and optional
page-turn effects. Keep smooth scroll from item 6 as the base.

---

## Later — bets, not commitments

| Item | Why it might matter | Why it waits |
|---|---|---|
| OPDS / Calibre / Calibre-Web | strong fit for self-hosted libraries | niche; adds a network surface |
| iOS packaging | README flags iOS as hard-broken | needs Rust FFI packaging and a maintainer |
| Home-screen widget / quick actions | convenience | no daily-reading impact |
| App-wide lock | privacy extension of the hidden-archive PIN | hidden archive already covers the sensitive case |
| Cloud progress sync | multi-device continuity | only after local backup is solid and proven |
| Audiobook support | adjacent market | different product surface |

---

## Not doing

These are deliberate anti-goals, not backlog items:

- **Built-in bookstore, DRM/LCP, or audiobook store.** Requires accounts,
  payments, and rights management; fights local-first.
- **Social features, public profiles, or reading feeds.** Not a reading task.
- **AI chat, "read this for me", or generated summaries.** Adds cost and
  dependency without helping someone finish their book.
- **Feature-parity for its own sake.** The target is the daily reading loop, not
  a checklist.
- **Office/HTML/CHM/DJVU document viewing.** Useful to some, but these are
  document-viewer features rather than e-book-reader table stakes.

---

## Decisions needed

These change what gets built, so they should be settled before the relevant
item starts. Recommended defaults are shown; they are proposals, not decisions.

| Decision | Affects | Recommended default |
|---|---|---|
| Is cloud sync in scope, or is local export enough? | item 2, Later | local export now; no cloud commitment |
| Is TTS core or an accessibility add-on? | item 3 | core, system TTS only |
| Which formats do actual users need: Kindle, FB2, or PDF/DJVU? | item 5 | Kindle (MOBI/AZW3) first, FB2 second |
| Is "minimal" a hard constraint? | Later, Not doing | yes; skip OPDS/widgets until asked for |
| Is English-only intentional for launch? | item 12 | no; pilot one locale after Now |

---

## How this stays current

- The gap map is the evidence; this file is the order of work.
- When an item gets a design doc, link it here under the item.
- When an item ships, move it to a **Shipped** line at the bottom of its phase
  with the release and commit range.
- If reality changes (a competitor ships something new, a user need surfaces),
  update `docs/feature-gap-map.md` first, then re-order here.
