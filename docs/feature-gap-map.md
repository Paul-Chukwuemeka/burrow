# Burrow — Missing Feature Map

Date: 2026-11-09
Scope: compare Burrow against (a) its README promises, (b) its own roadmap/design
docs, and (c) the feature sets of its main Android competitors.

Method: code inventory of `lib/`, all README/roadmap/design/plan docs in the
repo, and the official product pages listed at the end. Competitor claims are
taken from those pages, not from memory; `n/k` means "not confirmed on the
source page".

---

## 1. What Burrow is today

Positioning (from `README.md`): **a minimal, fast, local-first e-book reader for
Android**. That positioning matters: not every competitor feature is a gap —
some would actively fight the product's identity.

### Implemented and working

| Area | Shipped in Burrow | Evidence |
|---|---|---|
| Formats | EPUB, PDF, TXT, CBZ, CBR | `lib/models/book.dart` `BookFormat` |
| Content engine | Native Rust engine for EPUB/TXT/CBZ/CBR + PDF metadata stub; EPUB CSS, embedded fonts, image sizing | `rust/`, `lib/services/epub/`, `README.md` |
| Import | Two-phase import (instant filename title, background metadata), file picker, folder scan, device scan, share/open-with, Android `VIEW`/`SEND` intents | `library_service.dart`, `scan_service.dart`, `AndroidManifest.xml` |
| Library | Grid/list, sort by recent/added/title, filters by format/status/genre/series, title/author search, authors/series/genres screens | `library_screen.dart`, `library_filter_widgets.dart` |
| Organization | Collections (manual/alpha/recent), three fixed smart groups (Reading/Finished/New), multi-select batch actions | `library_screen.dart`, `smart_group_screen.dart` |
| Archive / trash | Normal archive, PIN-gated hidden archive, trash with restore/permanent delete | `archive_screen.dart`, `trash_screen.dart`, `archive_pin_service.dart` |
| Missing files | Startup sweep, storage-unavailable guard, missing badges, auto/manual relink, bulk remove | `library_service.dart`, `missing_matcher.dart` |
| Metadata | Edit all Dublin Core-ish fields; fetch covers/metadata from Google Books + Open Library | `edit_book_screen.dart`, `metadata_api_service.dart` |
| Reader | EPUB reflow pagination, 5 reader themes, 9 bundled fonts, font size/line height/margin/justification, TOC, bookmarks, in-book search, drag-to-select, define/copy/share selection toolbar | `reader_screen.dart`, `settings_sheet.dart`, `reader_settings.dart` |
| Dictionary | Offline Wiktionary (~50 MB), external dictionary app routing, Burrow registered as a native `DEFINE`/`PROCESS_TEXT` dictionary app | `dictionary_*.dart`, `external_dictionary_service.dart`, `AndroidManifest.xml` |
| PDF | Native render, outline, search, zoom, continuous scroll, vertical/horizontal LTR/RTL, text selection → define/copy/share | `reader_screen.dart`, `pdf_controller.dart` |
| Comics | Paginated/vertical, LTR/RTL, contain/fit-width/fit-height, zoom/pan, decode-ahead prefetch | `comic_controller.dart`, `comic_page_provider.dart`, `services/zoom/` |
| Stats | Today/week/month time, pages, sessions, average/longest, streak, heatmap, per-book stats | `stats_screen.dart`, `database.dart` |
| Comfort | Brightness (including below system), keep screen on, volume-key page turns, auto-resume last book, 3 app themes (light/dark/OLED) | `settings_screen.dart`, `reader_settings.dart` |

### Already differentiating (protect these)

- Local-first, no account, no cloud dependency; hidden archive with PIN.
- Rust content engine and two-phase import (fast library scans).
- Missing-file reconciliation and relink (most competitors just break).
- Offline dictionary + external dictionary chooser + being a dictionary app.
- Detailed reading stats.
- Material 3 Expressive library design and accessibility work.
- Comic reader with zoom/pan and RTL/vertical modes.

---

## 2. Gap source A — README promises

All five headline feature bullets are implemented. One wording gap:

| README claim | Reality | Gap |
|---|---|---|
| "Collections & Smart Groups — organize books manually or by rules (unread, finished, etc.)" | Smart groups are three hard-coded buckets: Reading, Finished, New. There is no user-defined rule builder. | **README overpromises.** Either add rule-based smart groups or reword to "fixed smart groups". |

Documentation gap (not a product gap): the README omits several shipped
features — archive, hidden archive, trash, multi-select, external dictionary,
define chooser, metadata fetch/edit, missing-file recovery, comic zoom. The
README is behind the code.

Known platform gap already declared in README:

- **iOS hard-fails.** Only Android packages the Rust `.so`; with the fallback
  removed, EPUB/TXT/CBZ/CBR reading cannot work on iOS until FFI packaging lands.

---

## 3. Gap source B — Burrow's own roadmap/design docs

There is **no single ROADMAP file**. Forward-looking intent is split across:

- `PLAN.md` — a post-review **bug-fix** plan, not a feature roadmap.
- `design/onboarding-redesign.md` — the only genuinely forward feature plan.
- `design/library-redesign.md` — shipped, with two accessibility follow-ups.
- `docs/superpowers/specs/` + `plans/` — feature specs/plans. Nearly all are
  shipped: missing files, multi-select, comic zoom, EPUB engine, drag selection,
  external dictionary, Wiktionary, native define chooser. The chess trainer was
  designed, built on a branch, then explicitly removed (`f0ac54a`).
- `PLAN.md` still has open quality nits (#11, #69–71), but no pending features.

### Onboarding redesign — mostly unbuilt

Actual flow is 4 pages: Welcome → Permission → Theme → Import. The redesign doc
proposes 6 steps across two tracks. Missing:

| Planned | Status |
|---|---|
| Track B "Personalize" toggle (Quick Start vs Customize) | Not built |
| Typography picker (Literata/Bitter/PT Serif/Atkinson preview) | Not built (theme is the only preference step) |
| Completion page ("Your burrow is ready" + summary) | Not built |
| "Onboarding" re-entry entry in Settings | Not built |
| "Browse sample/free books" for empty devices | Not built |
| Mini carousel of discovered covers after scan | Not built |
| A/B-testable, data-driven flow | Not built (flow is a fixed 4-page controller) |
| Analytics | Partial — `onboarding_analytics.dart` logs started/page/skip/permission/theme/scan/completed, but some redesign events (`format_selected`, `typography_selected`, `track_selected`) have no UI to fire from |
| Extract into ≤200-line sub-widgets | Partial — sub-widgets extracted, screen is ~439 lines (down from 1058) |

### Library redesign — shipped, with follow-ups

- TalkBack walkthrough on a real device.
- Dynamic-font check for the fixed-height grid text block.
- Both are accessibility hardening, not new features.

**Roadmap finding:** consolidate this into a real `ROADMAP.md`; right now
"roadmap" is tribal knowledge spread over a bug plan and two design docs.

---

## 4. Gap source C — competitors

Competitors surveyed (official pages, fetched 2026-11-09):

- **ReadEra** — `readera.org`
- **Moon+ Reader** — Google Play listing
- **PocketBook reader** — Google Play listing
- **Readest** — Google Play listing
- **KOReader** — GitHub README
- **Librera** — GitHub README (formats + OPDS only)

### Feature matrix

Legend: ✓ = supported, – = absent, ◐ = partial/limited, n/k = not confirmed.

| Capability | Burrow | ReadEra | Moon+ | PocketBook | Readest | KOReader | Librera |
|---|---|---|---|---|---|---|---|
| EPUB / PDF / TXT | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| CBZ / CBR comics | ✓ | ✓ | ✓ | ✓ | ◐ (CBZ) | ◐ (CBZ/CBT) | ✓ |
| MOBI / AZW3 | – | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| FB2 | – | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| DJVU | – | ✓ | ✓ | ✓ | – | ✓ | ✓ |
| DOC/DOCX/ODT/RTF | – | ✓ | ✓ | ✓ | – | ✓ (DOC/RTF) | ✓ |
| HTML / MD / CHM | – | – | ✓ | n/k | ✓ (MD) | ✓ | ✓ |
| Audiobooks / DRM / LCP | – | – | – | ✓ | – | – | – |
| Generic ZIP/RAR reading | ◐ (comic only) | ✓ | ✓ | n/k | – | ✓ (some) | ✓ |
| Auto-detect library | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Grid/list, sort, filter | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Collections | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| User-defined smart shelves/tags | – (fixed 3 groups) | ✓ (lists/collections) | ✓ (tags) | ✓ | ✓ (custom groups) | ✓ (collections) | n/k |
| Duplicate detection | – (path only) | ✓ | n/k | n/k | n/k | n/k | n/k |
| OPDS / Calibre | – | – | ✓ (OPDS) | – (store) | ✓ | ✓ | ✓ |
| Built-in book store | – | – | – | ✓ | – | – | – |
| Cloud sync / backup | – | – | ✓ (Dropbox/WebDAV) | ✓ (free cloud) | ✓ (multiple) | ✓ (progress sync) | n/k |
| Metadata fetch/edit | ✓ | ✓ (auto) | ✓ | ✓ | ✓ (Calibre) | ✓ (Calibre) | n/k |
| Archive / trash / hidden shelf | ✓ (unique) | – | – | – | – | – | – |
| Multi-select batch actions | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | n/k |
| Custom font import | – (9 bundled) | ✓ | ✓ (Pro) | ✓ (26-format reader) | ✓ | ✓ | n/k |
| Hyphenation | – | ✓ | ✓ | n/k | n/k | ✓ | n/k |
| Continuous scroll (reflowable) | – (paginated only) | ✓ (H/V paging) | ✓ (smooth scroll) | n/k | ✓ | ✓ | n/k |
| Page-turn effects | ◐ (PageView slide only) | n/k | ✓ (5 effects) | n/k | ✓ | n/k | n/k |
| Dual-page / landscape | – | – | ✓ | n/k | ✓ | ✓ | n/k |
| Auto-scroll | – | – | ✓ (5 modes) | – | – | ✓ | n/k |
| Reading ruler | – | – | ✓ | – | – | – | n/k |
| In-book search | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | n/k |
| Bookmarks | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | n/k |
| In-text highlights / quotes | – | ✓ | ✓ | ✓ | ✓ | ✓ | n/k |
| In-text notes/annotations | – (book-level field only) | ✓ | ✓ | ✓ | ✓ | ✓ | n/k |
| Export annotations | – | n/k | ✓ (Pro share) | n/k | ✓ | ✓ | n/k |
| Dictionary lookup | ✓ (offline Wiktionary + external apps) | ✓ (device dictionaries) | ✓ | ✓ | ✓ | ✓ (StarDict) | ✓ |
| Translation | – (share is the workaround) | ✓ | ✓ | n/k | ✓ (sentence/page/book) | ✓ (Google Translate) | n/k |
| Wikipedia lookup | – | – | – | – | ✓ | ✓ | n/k |
| TTS / read aloud | – | ✓ | ✓ (Pro) | ✓ | ✓ (offline voices) | ◐ (plugin) | n/k |
| PDF zoom / search / outline | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| PDF crop margins | – | ✓ | n/k | n/k | n/k | ✓ | ✓ (MuPDF) |
| PDF reflow | – | – | n/k | n/k | – | ✓ | n/k |
| PDF/DjVu annotations | – | n/k | ✓ | ✓ | ✓ (highlights) | ✓ | n/k |
| Comic zoom/pan + RTL/vertical | ✓ | ✓ | ✓ | ✓ | ◐ | ✓ | ✓ |
| Reading stats | ✓ (strong) | – | ✓ (Pro) | n/k | n/k | ✓ | n/k |
| Reading goals | – | – | n/k | n/k | n/k | n/k | n/k |
| Full-text library search | – (title/author only) | – | n/k | n/k | – (in-book only) | n/k | n/k |
| UI localization | – (English only) | ✓ (57+ languages) | ✓ (40 languages) | ✓ | ✓ | ✓ | ✓ |
| Cross-platform | – (Android only; iOS broken) | ✓ (Android/iOS) | – (Android) | ✓ (Android/iOS) | ✓ (all major + web) | ✓ (many devices) | – (Android) |
| App lock / password | ◐ (hidden-archive PIN only) | – | ✓ (Pro) | n/k | n/k | – | n/k |
| Kids mode | – | ✓ | – | – | – | – | – |
| Home-screen widgets/shortcuts | – | – | ✓ (Pro) | n/k | n/k | – | n/k |
| Multiple books side by side | ◐ (OS split-screen) | ✓ | – | ◐ (requested) | ✓ (up to 4) | – | n/k |
| Custom gestures/key bindings | – | – | ✓ (24 actions) | – | – | ✓ | n/k |
| Android Auto | – | – | – | – | ✓ | – | – |
| E-ink optimization | – | – | – | – | ✓ | ✓ | n/k |
| Open source | – | – | – | – | ✓ | ✓ | ✓ |

### What the matrix says

Burrow already leads or matches on: local privacy, archive/trash, missing-file
recovery, metadata editing, dictionary/define integration, comic reading, stats,
Material 3 design, and performance.

Burrow is a **table-stakes gap** on the cluster that most readers use daily:

1. **Highlights/quotes + notes** (missing entirely; only bookmarks and a
   book-level "Review & notes" text field).
2. **TTS / read aloud** (missing; four of six competitors have it).
3. **Translation** (missing; dictionary only looks up words).
4. **Cloud sync/backup** (missing; three competitors sync progress/notes, and
   Burrow has no export at all).
5. **Format breadth** (MOBI/AZW3/FB2 are the common Kindle/FB2 formats; DJVU and
   Office are more niche).
6. **Custom font import + continuous scroll + hyphenation** (reading comfort
   features that competitors treat as standard).
7. **Localization** (English-only blocks most non-English markets).
8. **Cross-platform** (iOS is explicitly broken; desktop/web absent).

Secondary gaps: OPDS/Calibre, duplicate detection, full-text library search,
page-turn effects, dual-page, widgets, app lock, kids mode.

---

## 5. Prioritized missing-feature roadmap

Ordering weighs user value, how often competitors ship it, and fit with
"minimal, fast, local-first".

### P0 — close table-stakes gaps (next two releases)

| # | Feature | Why now | Minimal shape |
|---|---|---|---|
| 1 | In-text highlights + notes + export | The single biggest functional gap; turns Burrow from "reader" into "reading tool". | New `Highlights` table (`bookId`, chapter, start, end, color, note, createdAt); selection toolbar "Highlight"/"Note"; a Quotes/Notes tab beside TOC/Bookmarks; export Markdown/JSON. |
| 2 | Backup / restore (local first) | Burrow has no export; a lost phone loses the library index, bookmarks, sessions, covers. Competitors sync. | Export a single archive: DB JSON + covers; import via file picker; optional WebDAV/Google Drive later. Reuse `LibraryService` serialization paths. |
| 3 | TTS / read aloud | Expected by mainstream readers; helps accessibility. | Android system TTS with sentence range highlight, speed/pitch, play/pause in chrome; no cloud voice. |
| 4 | Direct translation action | Dictionary exists; translation is the natural next step. | Add "Translate" to the selection toolbar, routing to installed translator apps or an optional API; no bundled translation model. |
| 5 | Format phase 1: MOBI/AZW3/FB2 | Kindle and FB2 libraries are common; ReadEra/Librera/Moon+/KOReader all cover them. | Add to `BookFormat`, parser path in Rust, metadata extractor, manifest MIME types, filters. |
| 6 | Custom font import + continuous scroll | Two comfort features every serious competitor has. | Import `.ttf`/`.otf` into app storage + `FontLoader`; add a scroll mode for reflowable chapters (reuse comic/PDF scroll patterns). |

### P1 — finish the committed roadmap + library depth

| # | Feature | Source |
|---|---|---|
| 7 | Rule-based smart groups (or reword README) | README promise |
| 8 | Onboarding: typography step, completion page, Settings re-entry, sample books | `design/onboarding-redesign.md` |
| 9 | Duplicate detection (size + partial hash) | ReadEra |
| 10 | Full-text library search | Large-library usability |
| 11 | Reading goals + stats export | Natural extension of existing stats |
| 12 | Localization framework + first non-English locale | Competitor norm |
| 13 | Hyphenation + dual-page/landscape + page-turn effects | Reader polish |

### P2 — reach and power users

| # | Feature | Notes |
|---|---|---|
| 14 | OPDS / Calibre / Calibre-Web | Strong fit for self-hosted library users; optional, not core. |
| 15 | iOS FFI packaging + cross-platform evaluation | README already flags iOS as hard-broken. |
| 16 | Home-screen widget / quick actions | Convenience; Moon+ Pro has it. |
| 17 | App-wide lock (not just hidden archive) | Privacy extension of existing PIN work. |
| 18 | Cloud progress sync (WebDAV/Drive) | Only after local backup is solid. |

### Deliberate non-goals (recommended)

- Built-in bookstore, DRM/LCP, audiobook store, accounts, social features, AI
  chat, or "read this for me" features — all fight the minimal/local-first
  identity.
- Office/HTML/CHM/DJVU support can wait; they are document-viewer features, not
  e-book-reader table stakes.
- Feature-parity for its own sake is the wrong target. The goal is: **no daily
  reading task forces the user to another app.**

---

## 6. Immediate quick wins (low effort, high signal)

1. Reword README smart-group bullet, or ship rule-based groups (P1).
2. Add an "Export library" action — even JSON-only is better than nothing.
3. Add Highlights table + selection-toolbar action before building the notes UI.
4. Add "Translate" to the selection toolbar as an Android intent (no backend).
5. Add the onboarding completion page + Settings re-entry (design already written).
6. Create `ROADMAP.md` from this document and link it from README.

---

## 7. Decisions needed from the product owner

1. **Is cloud sync in scope, or is local export enough?** (affects P0 #2 shape)
2. **Is TTS a core feature or an accessibility add-on?** (affects investment)
3. **Which format expansion matters to actual users: Kindle (MOBI/AZW3), FB2, or
   PDF/DJVU?**
4. **Is "minimal" a hard constraint?** If yes, skip OPDS/widgets/kids mode and
   focus on the daily-reading cluster.
5. **Is localization needed for launch, or is English-only intentional?**

---

## 8. Evidence index

Repo:

- `README.md` — positioning, feature promises, iOS known issue.
- `PLAN.md` — bug-fix plan; open nits only.
- `design/onboarding-redesign.md` — unbuilt onboarding phases.
- `design/library-redesign.md` — shipped design + accessibility follow-ups.
- `docs/superpowers/specs/`, `docs/superpowers/plans/` — shipped feature specs.
- `lib/models/book.dart`, `lib/models/reader_settings.dart`, `lib/db/database.dart`
  — formats, settings, persisted models (no highlights table).
- `lib/screens/library_screen.dart`, `reader_screen.dart`, `settings_screen.dart`,
  `stats_screen.dart`, `onboarding_screen.dart` — shipped UI.
- `lib/services/library_service.dart`, `metadata_api_service.dart`,
  `dictionary_*.dart`, `book_search.dart` — service capabilities.
- `android/app/src/main/AndroidManifest.xml` — `VIEW`/`SEND`/`DEFINE` intents.

Competitors (fetched 2026-11-09):

- ReadEra — https://readera.org/
- Moon+ Reader — https://play.google.com/store/apps/details?id=com.flyersoft.moonreader
- PocketBook reader — https://play.google.com/store/apps/details?id=com.obreey.reader
- Readest — https://play.google.com/store/apps/details?id=com.bilingify.readest
- KOReader — https://github.com/koreader/koreader
- Librera — https://github.com/foobnix/LibreraReader
