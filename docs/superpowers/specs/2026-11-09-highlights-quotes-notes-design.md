# Highlights, Quotes, and Notes — Design

Date: 2026-11-09
Status: Draft for review
Scope: Burrow Flutter reader (`lib/`), Drift schema, reflowable reader
(EPUB/TXT), PDF reader, table-of-contents sheet, and export.

## 1. Intent and why

Burrow can select and copy text, but it cannot keep it. A reader who wants to
remember a passage has to leave the app and paste it somewhere else. Every
surveyed competitor keeps highlights and notes; this is the largest daily-use
gap in the product.

The feature turns Burrow from a reader into a reading tool without adding an
account, a network dependency, or a new document format. A highlight is a local
record tied to a book, a locator, an optional note, and a colour. It is never
written back into the book file.

Success test: select a sentence, add a thought to it, close the app, reopen the
book a week later, find the quote in one list, tap it, and land on the exact
passage — with the app offline the whole time.

## 2. Goals

- Keep a highlight from EPUB, TXT, and text-layer PDFs.
- Attach one optional note to a highlight.
- Show all highlights for a book in reading order.
- Jump from a highlight back to its passage.
- Export a book's highlights as Markdown and JSON.
- Survive app restarts, theme changes, font/size changes, and pagination
  reflows.
- Stay fast: highlighting must not slow page paint or book opening.

## 3. Non-goals

- Handwriting, freehand ink, shapes, or image annotations.
- Writing annotations into the PDF/EPUB file.
- Comic (CBZ/CBR) highlights. Comics have no text layer in Burrow.
- Cloud sync or cross-device merge. Local only for now.
- Sharing a single highlight as an image or card.
- Full-text search across highlights, tag systems, or folders.
- Highlighting scanned PDFs with no text layer.
- Custom user-defined highlight colours (a fixed palette only).

## 4. Anti-goals (what would make this a failure)

- A highlight that disappears after a font-size change or app update without a
  clear explanation.
- A visible stall when opening a heavily highlighted book.
- A toolbar that pushes Define/Copy/Share off screen on a 320 dp phone.
- Export that produces text Burrow cannot re-import or read.
- Deleting a book without telling the reader that its highlights go with it.

## 5. Constraints

- Flutter + Drift. No new dependency is required.
- Offline, no account. Export goes through the Android share sheet or a local
  file save.
- The reader already has two different locator systems; the schema must respect
  both instead of forcing one.
- Page rendering must not call the database per frame.
- Existing books, bookmarks, progress, and collections must survive the
  migration unchanged.

## 6. Architecture overview

```
selection (reflowable) ──► HighlightDraft ──► LibraryService.addHighlight
selection (PDF)       ──┘                         │
                                                  ▼
                                          Highlights table (v9)
                                                  │
              ┌───────────────────────────────────┼─────────────────────┐
              ▼                                   ▼                     ▼
   Reader page spans                   TOC sheet "Notes" tab      HighlightExporter
   (coloured background)               (list, edit, delete, jump) (Markdown / JSON)
                                                  │
                                                  ▼
                                            PDF paint callback
```

One table, one service surface, one list. Format differences live in nullable
locator columns, not in parallel features.

## 7. Data model

### 7.1 New table (`lib/db/database.dart`)

```dart
class Highlights extends Table {
  TextColumn get id => text()();
  TextColumn get bookId => text().references(Books, #id)();
  TextColumn get text => text()();                 // selected plain text
  TextColumn get note => text().withDefault(const Constant(''))();
  IntColumn get color => integer().withDefault(const Constant(0))(); // palette index

  // Reflowable locator (EPUB/TXT). Offsets are chapter-local code units.
  IntColumn? get chapter => integer().nullable()();      // start chapter
  IntColumn? get startOffset => integer().nullable()();  // inclusive
  IntColumn? get endChapter => integer().nullable()();
  IntColumn? get endOffset => integer().nullable()();    // exclusive

  // PDF locator. `page` is 1-based, matching pdfrx.
  IntColumn? get page => integer().nullable()();
  TextColumn? get segments => text().nullable()();       // JSON, see 7.2

  IntColumn get createdAt => integer()();
  IntColumn? get updatedAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
```

Rules enforced in `LibraryService`, not in SQLite:

- Exactly one locator family is present: either reflowable fields or PDF
  fields, never both.
- Reflowable: `startOffset >= 0`, `endOffset > startOffset` when the same
  chapter, and `endChapter >= chapter`.
- PDF: `page >= 1` and `segments` is valid JSON.

### 7.2 PDF segments

A PDF selection can span pages and lines. Store line-level rectangles so the
render is tight instead of one large bounding box:

```json
[
  {"page": 12, "rects": [[74.1, 700.2, 412.8, 688.0], [74.1, 686.1, 300.4, 673.9]]}
]
```

- `page` is 1-based.
- Each rect is `[left, top, right, bottom]` in **PDF page coordinates**, using
  pdfrx's `PdfRect` convention (`top > bottom`).
- Rects come from `PdfPageTextRange.enumerateFragmentBoundingRects()`, not from
  the union `bounds`.
- At render time, reconstruct `PdfRect(left, top, right, bottom)` and call
  `toRectInDocument(page: page, pageRect: pageRect)`. Do not store screen
  coordinates: they change with zoom and rotation.

### 7.3 Migration to schema v9

- Bump `schemaVersion` from 8 to 9.
- `onCreate` is already handled by `createAll()` once `Highlights` is in the
  table list.
- `onUpgrade`: if `from < 9`, create the table if missing and add
  `idx_highlights_book_id`.
- Follow the existing "check before add" pattern so a crash mid-migration
  cannot leave a half-created schema.
- `deleteBookById` must delete that book's highlights in the same transaction
  as bookmarks, sessions, and collection links.
- Deleting a book is not silent about annotations: the single-book and batch
  remove confirmations add a line such as "Also deletes 3 highlights." A count
  query is enough; do not build an export-before-delete flow in v1.

Index: `(book_id)` for the per-book load. No index on chapter: the in-memory
list is small and filtered per page.

## 8. Locator conversion

Add pure helpers in `lib/utils/highlight_locator.dart` so the reader, service,
and exporter share one implementation:

```dart
/// Flat document offset -> (chapter, chapter-local offset).
({int chapter, int offset}) splitFlatOffset(int flat, List<int> charsBefore);

/// Chapter-local offset -> flat document offset.
int flatOffsetFor(int chapter, int offset, List<int> charsBefore);

/// Clamp a stored locator to the current parse.
({int chapter, int start, int end})? clampReflowableLocator(
  Highlight h, int chapterCount, int Function(int) chapterLength,
);
```

The last function is the safety valve for parser changes: if a stored chapter
no longer exists or its offsets exceed the body length, clamp for the jump and
keep the stored data. Export never depends on a successful clamp because the
selected `text` is stored.

A highlight that cannot be clamped is still listed in the Notes tab with a
**Location unavailable** locator. Tapping it does nothing (or shows a toast);
edit, colour, export, and delete still work. It is never hidden and never
deleted automatically: disappearing annotations would be worse than a dead
jump.

## 9. Capture

### 9.1 Reflowable (EPUB/TXT)

`_showSelectionToolbar` currently passes only the rendered text. Extend it to
pass the selection's flat `start` and `end` as well.

- **Highlight**: convert flat range to `(chapter, startOffset)` and
  `(endChapter, endOffset)`, then `addHighlight` with the last-used colour.
- **Note**: open a note dialog first; saving creates the highlight with the note.
  Cancelling creates nothing.
- Both actions clear the selection and dismiss the toolbar after the write.
- Empty or whitespace-only selections do nothing (already prevented by the
  existing `text.trim().isEmpty` check).

The stored offsets are chapter-local, so changing font size, line height,
margins, theme, or pagination cannot move them. Re-parsing the same file with
the same engine produces the same chapter bodies, so offsets stay valid across
normal restarts.

### 9.2 PDF

The existing `onTextSelectionChange` callback receives a `PdfTextSelection`, but
it currently shows the Burrow toolbar only for selections under 50 characters
and passes only the first word. Replace that gate: **any non-empty PDF
selection** shows the full toolbar with Define disabled (the selection is not a
single word) and Copy, Share, Highlight, and Note enabled.

While the selection is live, capture:

- `text = await selection.getSelectedText()`.
- `ranges = await selection.getSelectedTextRanges()`.
- For each range, `page = range.pageNumber` and
  `rects = range.enumerateFragmentBoundingRects().map((r) => r.bounds)`.

Store the resulting segments JSON. This capture is asynchronous; keep the draft
in reader state until the toolbar action fires, and discard it when the
selection is cleared or replaced.

**One menu, not two.** pdfrx shows its own Copy/Select All context menu on
touch by default. Set
`PdfViewerParams.buildContextMenu: (context, params) => null` so Burrow's
toolbar is the only selection UI. Otherwise two competing menus appear and the
native one can clear the selection before Highlight/Note captures it.

**Placement.** Keep the current centred placement in v1. Mapping the selection
anchor rect back into viewer coordinates adds work without changing what gets
built; the PDF toolbar already uses a modal barrier, so a centred bar is
usable. A future pass can anchor it to the selection handle.

### 9.3 Toolbar behaviour

The toolbar becomes: **Define** (single word only), **Copy**, **Share**,
**Highlight**, **Note**. Five text buttons do not fit on a 320 dp phone, so:

- Cap the row width at `screenWidth - 16`.
- Wrap it in a horizontal `SingleChildScrollView`; no button is ever off screen
  without a scroll affordance (edge fade).
- Keep the current text labels; do not replace them with unlabelled icons.
- `Semantics(button: true)` labels come from the text itself.

The last-used colour is persisted in `ReaderSettings.highlightColorIndex`
(default 0). Changing colour happens from the Notes tab edit dialog in v1.

## 10. Rendering

### 10.1 Reflowable pages

- `HighlightController` (new `ChangeNotifier`, mirrors `BookmarkHelper`) loads
  all highlights for the open book once and exposes them grouped by chapter.
- On each page build, pass only the slices that overlap the current page:
  `buildPageSpans` gains
  `List<({int start, int end, int color})> highlightSlices`.
- Slice offsets are chapter-local. The caller clips with the existing
  `pageLocalRange` helper.
- `buildPageSpans` adds highlight boundaries to its cut set and paints the
  background per segment:
  - light themes: `palette[color].withValues(alpha: 0.35)`
  - dark/OLED themes: `palette[color].withValues(alpha: 0.28)`
- The live text selection paints on top of a highlight; selection wins where
  they overlap.
- Background colour does not affect text metrics, so pagination is unchanged.

### 10.2 PDF pages

- Extend `PdfViewerParams` with a `pagePaintCallbacks` entry.
- For the page being painted, find segments with `page == page.pageNumber`.
- Reconstruct each `PdfRect`, call `toRectInDocument`, and fill with the
  highlight colour at the same alphas.
- Filter by page first; the callback runs per visible page and must not scan
  every highlight in the book.

## 11. Notes tab and editing

`TocSheet` already owns `Contents | Bookmarks` tabs for both reflowable and PDF
books. Add a third tab, **Notes** (the label covers quotes and notes):

- Tab shows a count, e.g. `Notes 12`.
- Sorted by reading order: reflowable `(chapter, startOffset)`, PDF
  `(page, first rect top, left)`. Newest-first is wrong here; reading order is
  what a reader expects when revisiting a book.
- Each row shows: colour dot, selected text (max 4 lines), note preview, and a
  locator (`Chapter title` or `Page N`) plus date.
- Tapping a row jumps and closes the sheet.
- Row overflow: **Edit note**, **Change colour**, **Delete**.
  - Edit note: multiline dialog, Save/Cancel. Empty note is allowed (quote
    only).
  - Change colour: five named swatches; a check mark marks the current one so
    colour is not the only signal.
  - Delete: remove immediately and show an undo snackbar. No blocking
    confirmation.
- Rows whose reflowable locator cannot be clamped show **Location unavailable**
  and a disabled jump. They remain editable, exportable, and deletable.
- The TOC button must always open the sheet, including for PDFs with no
  outline. `_showTocSheet` currently returns early when
  `pdfOutline.isEmpty`; remove that guard and let the Contents tab show
  "No contents". Otherwise Notes is unreachable for a large class of PDFs.
- Empty state: "No highlights yet. Select text while reading to keep a quote."
- The tab is hidden for comics, consistent with the existing TOC/bookmark
  hiding rules.

Numbering and subtitles for reflowable rows use `Chapter.title`; PDF rows use
`Page N`.

## 12. Export

New pure service `lib/services/highlight_exporter.dart`:

```dart
String toMarkdown(Book book, List<Highlight> highlights,
    {required String Function(Highlight) locatorLabel});
String toJson(Book book, List<Highlight> highlights);
```

- **Markdown**: title/author header, export date, then groups in reading order.
  Reflowable groups are `## Chapter title`; PDF groups are `## Page N`.
  Quotes are blockquotes, notes follow as `**Note:** …`, and blank selections
  are skipped.
- **JSON**: `{"version":1,"book":{...},"exportedAt":...,"highlights":[...]}`.
  Include the locator fields and `segments`, so a future import can reconstruct
  the record.
- **Delivery**: write to the app cache directory, then share the file with
  `SharePlus.instance.share(ShareParams(files: [XFile(path)]))`. No storage
  permission and no new plugin.
- **Entry point**: overflow menu in the Notes tab → **Export highlights** →
  choose Markdown or JSON.
- Filename: sanitized `<title> — highlights.md` / `.json`.

Export is a read-only operation and must work with zero highlights by showing a
disabled menu item.

## 13. Files touched (planned)

| Area | File |
|---|---|
| Schema + migration | `lib/db/database.dart` |
| Service API | `lib/services/library_service.dart` |
| Locator helpers | `lib/utils/highlight_locator.dart` (new) |
| Controller | `lib/controllers/highlight_controller.dart` (new) |
| Selection toolbar | `lib/widgets/selection_toolbar.dart`, `lib/controllers/selection_toolbar.dart` |
| Reflowable rendering | `lib/utils/page_spans.dart`, `lib/screens/reader_screen.dart` |
| PDF rendering + capture | `lib/screens/reader_screen.dart` |
| List/edit UI | `lib/widgets/toc_sheet.dart` |
| Export | `lib/services/highlight_exporter.dart` (new) |
| Settings default colour | `lib/models/reader_settings.dart` |
| Delete confirmations | `lib/screens/library_screen.dart` (count line) |

## 14. Testing

Unit:

- Locator split/join round-trips, including chapter boundaries and empty
  chapters.
- Clamp behaviour when a chapter is missing or shorter than the stored range.
- Segment JSON round-trip: order, 1-based page, `top > bottom`.
- Markdown/JSON output for zero, one, and many highlights; cross-chapter
  highlights; PDF multi-page selections.
- `buildPageSpans` paints a highlight and lets selection override it.
- A highlight that cannot be clamped still appears with the unavailable
  locator and remains exportable.

Database:

- Insert, read in reading order, update note/colour, delete.
- `deleteBookById` cascades to highlights.
- Fresh DB at v9 creates the table and index.
- Migration from a v8 database preserves books, bookmarks, and sessions.

Widget:

- Toolbar shows Define only for a single word and Highlight/Note always.
- Toolbar remains reachable at 320 dp width.
- Notes tab lists items, jumps on tap, edits a note, changes colour, deletes
  with undo.
- Notes tab is reachable for a PDF with no outline.
- Delete confirmation mentions the number of highlights that will go with the
  book.
- Empty state renders.

Manual (device):

- EPUB: highlight across a page turn and a chapter boundary; change font size;
  restart; jump back.
- TXT: same flow.
- PDF: multi-line and multi-page selection; zoom and rotate; restart; jump back.
- Dark/OLED themes: highlight remains readable.
- TalkBack: toolbar buttons, list rows, colour swatches, note dialog.

## 15. Performance budget

- One DB query per book open, not per page.
- Per page: O(highlights overlapping that chapter); no JSON parsing of PDF
  segments for reflowable books.
- Per PDF page paint: filter by page number, then draw; no DB access.
- Highlighting must not add a perceptible pause to the existing selection
  toolbar; the write is a single local insert.

## 16. Known limitations (accepted for v1)

- If the EPUB parser changes how a chapter's body is produced, stored offsets
  can drift. The stored selection text is the durable record; the jump clamps
  rather than fails.
- Scanned PDFs without a text layer cannot be highlighted.
- Highlights are local to the device; there is no sync.
- Overlapping highlights are allowed; there is no merge or dedupe.
- Tapping highlighted text itself does not open the note in v1; the Notes tab
  is the editing surface. This avoids text hit-testing work and keeps the first
  version small.

## 17. Builder's calls

These were decided during design rather than requested:

- One table with nullable locator families instead of two tables.
- Chapter-local offsets for reflowable text, not flat offsets: settings and
  pagination changes must never move a highlight.
- PDF line-level rects instead of a single bounding box.
- Notes and quotes share one list and one export path.
- Fixed five-colour palette; colour changes happen from the list, not the
  selection toolbar.
- Delete is immediate with undo, not a confirmation dialog.
- Export goes through the share sheet; no file-picker save flow in v1.
- pdfrx's own selection menu is suppressed; Burrow's toolbar is the only PDF
  selection UI, and the 50-character gate is removed.
- Book deletion stays a single confirmation, with the highlight count added to
  its text instead of an export-before-delete flow.
- The TOC button always opens the sheet, even when a PDF has no outline.
- Highlights that no longer clamp stay listed with a disabled jump.

## 18. Open questions

None blocking. The user has already settled the product-level decisions
(local only, minimal, English only). Remaining choices are within the
builder's discretion and are listed in §17.
