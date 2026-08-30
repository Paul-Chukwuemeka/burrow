# burrow — Library Redesign (Material 3 Expressive)

Implementation status: **shipped** on `lib/screens/library_screen.dart` and
supporting files. This document is the component/behaviour contract behind the
code; every named token or widget below is real and test-enforced.

Run `flutter run` and toggle platform dark mode to review light/dark.

---

## Deliverable 1 — Fixed Library Home (light + dark)

Verification checklist against §1 bugs, visible in both themes:

| Bug | Fix | Where |
| --- | --- | --- |
| FAB overlaps last row | Grid reserves `Burrow.fabClearance` (= FAB 60 + margin 16 + gap 28) as bottom scroll inset | `library_screen.dart` → `_libraryContent` |
| Broken PDF placeholders | Designed placeholder: wrapped title, format-keyed textured gradient, format icon, format label | `book_cover.dart` → `_PlaceholderCover` |
| Inconsistent aspect ratios | Every cover renders in a strict 2:3 frame (`Burrow.coverAspectRatio`); grid extents are computed from tile width; real art center-crops via `BoxFit.cover` | `_bookGrid`, `BookCover(enforceAspect)` |
| Truncated filename cruft | `_OceanofPDF.com_The_Forever_Hero_by_John_Doe.pdf` → "The Forever Hero"; cleanup at import time *and* lazily at display time for legacy entries; titles ellipsize at 2 lines | `utils/book_title.dart`, `Book.displayTitle` |
| No progress bar in grid | Thin segmented bar over the cover once reading starts; "New" books show no bar and no "0%" | `_CoverArea`, convention below |
| Cards lack containment | Tiles are tonal cards (`surfaceContainerLow`) with medium squircle + hairline outline + soft shadow | `_BookTile` |
| Bare header | Wordmark row: primary squircle mark + "burrow" in Roboto Flex w800 | `_BurrowHeader` |

**Progress convention (one rule everywhere):**

| State | Bar | Label | Screen reader |
| --- | --- | --- | --- |
| Never opened | none | `New` | "Not started" |
| Started | segmented fill | `NN%` | "NN percent read" |
| Finished | full | `Finished` ✓ | "Finished" |

Enforced by `Book.progressSemantics` / `showProgress` and asserted in tests.

---

## Deliverable 2 — Placeholder Cover Spec

Component: `lib/widgets/book_cover.dart` → `BookCover(book, borderRadius,
spine, enforceAspect)`.

Geometry
- Frame: strict **2:3 portrait**, independent of parent constraints when
  `enforceAspect` (default true). Real artwork fills with `BoxFit.cover`.

Background (per file format, deterministic per title)
- Hue bands — EPUB `96°–152°` forest greens · TXT `26°–46°` ochre ·
  PDF `4°–22°` clay/rust.
- Title hash picks one hue inside the band; gradient stops:
  lift `HSL(h, .38, .44)` → base `HSL(h, .44, .34)` → deep `HSL(h, .50, .20)`
  across the diagonal.
- Texture layer (`_PlaceholderTexture`): 6px white @5% diagonal hatching,
  top-left radial highlight, bottom vignette, and a short "gilt" rule above
  the title block.

Content column
- Top-left: 17dp circle chip @16% white holding the format icon
  (EPUB `menu_book`, TXT `article`, PDF `picture_as_pdf`).
- Middle: cleaned title, centered, auto-fits by shrinking 15→8.5sp until it
  wraps within **max 3 lines** (`_FittedTitle`); author line beneath when
  metadata exists.
- Bottom: format name, 7sp caps, +200% letterspacing.

Contrast contract (test-enforced)
- White ink vs base stop ≥ **4.5:1** (AA normal text) and vs deep ≥ **7:1**
  for every band endpoint and midpoint. The lighter lift tone only touches
  the icon corner (icon = large glyph, AA-large applies).

---

## Deliverable 3 — Component Spec (shape · color · type)

Tokens live in `lib/theme/burrow_tokens.dart` (`Burrow.*`).

### Shape scale (deliberately non-uniform)

| Token | Value | Applied to |
| --- | --- | --- |
| `shapeXs` | 6 | progress-bar segments, format badges |
| `shapeSm` | 12 | filter chips, header mark, sheet actions |
| `shapeMd` | 16 | grid book cards, list tiles, card theme |
| `shapeLg` | 28 | Continue-Reading hero, FAB, search field focus |
| `shapeXl` | 32 | bottom sheets |

Corners round in one direction family (uniform superellipse), hero shares the
grid's rounding language scaled up — hierarchy reads as one system.

### Color roles

Brand seed stays the earthy green `#2E6E4E`; M3 tonal palette derives all
roles from it. Saturation budget:

- Most saturated = **primary**, reserved for exactly two elements: the FAB
  and selected filter chips. Hero card uses `primaryContainer`.
- Format badges are tonal chips, never flat black:
  - EPUB → `primaryContainer / onPrimaryContainer`
  - TXT → `#FFE3BC/#5A421A` (light) · `#503B14/#FFDDA4` (dark)
  - PDF → `#FFDACF/#66241A` (light) · `#5A2117/#FFB5A1` (dark)
  (`Burrow.formatTonal`)
- Grid progress bars are neutral white-on-scrim so they never compete with
  the primary actions.

### Type scale (Roboto Flex variable font, bundled)

| Role | Spec |
| --- | --- |
| App wordmark | headlineSmall, w800, ls −0.5 (no icon; compact collapsing bar) |
| Section header ("All books · N") | titleMedium, w700 — own step above card titles |
| Hero title | titleLarge, w800, max 2 lines |
| Grid title | bodySmall 12.5, w700, h 1.2, max 2 lines |
| Metadata/status | labelSmall 11, w500–700, 1 line |
| Placeholder title | auto-fit 15→8.5sp bold |

---

## Deliverable 4 — Motion Storyboard

All timings use Material easing (`Easing.emphasized*`).

1. **Opening a book** — press grid card: spring compress ×0.96 (90ms down /
   220ms easeOutBack release) → cover lifts out of the card as a **Hero
   flight** (`tile-<id>` / `hero-<id>`) into the reader's landing pad,
   centered at 62% width → holds ~300ms while text settles behind → cover
   dissolves (emphasizedAccelerate) and unmounts. Back: cover flies home.
2. **Adding a book** — icon-only FAB rotates +45°, tints to secondary
   container, scrim fades; menu items stagger in right-to-left (scale 0.8→1,
   slide 24dp, 380ms, emphasizedDecelerate). Import runs under a linear
   determinate bar; new tiles reveal staggered (40ms/item, fade+slide+scale).
3. **Filtering** — tapped chip cross-fades outline↔filled-primary instantly
  (no travel); grid re-reveals via the staggered entrance so count change
   reads as re-flow, not teleport; section header updates ("N found").
4. **Reading progress** — hero bar animates 0→value over 900ms
   emphasizedDecelerate on build; grid bars render settled (`animate:false`)
   to avoid 10 simultaneous tweens; fill is **segmented** (9px dash / 3px gap
   hero, 6/2 grid) so small percentages stay legible.

---

## Deliverable 5 — Accessibility Checklist

Test-enforced items live in `test/widget_test.dart` → `Accessibility` group.

- [x] **Touch targets ≥48dp**: filter chips guaranteed by `_PillChip`
      constraints (survives ambient ChipTheme); sort pill, sheet rows (72dp),
      FAB menu icons (54dp), empty-state buttons (54dp) all clear.
- [x] **WCAG 2.1 AA contrast**: placeholder ink computed per band endpoint +
      midpoint — white/base ≥4.5:1, white/deep ≥7:1; tonal badge pairs chosen
      ≥7:1 both modes; primary-on/onPrimary pairs from seeded scheme.
- [x] **One screen-reader convention**: merged tile node announces
      `<Title>. by <Author>. <progressSemantics>` with hint "Double tap to
      read; long press for options"; hero announces "Continue reading …";
      unstarted = "Not started" (never "0%"); finished = "Finished".
- [x] Section header flagged `Semantics(header: true)`; decorative intro
      overlay wrapped in `ExcludeSemantics` + `IgnorePointer`.
- [x] Chip selection state exposed via `Semantics(selected:)`.
- [ ] Follow-up: TalkBack walkthrough on device; dynamic-font check for the
      fixed-height grid text block (ellipsis currently absorbs large-font
      overflow).
