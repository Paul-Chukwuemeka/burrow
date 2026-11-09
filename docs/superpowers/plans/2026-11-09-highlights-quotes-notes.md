# Highlights, Quotes, and Notes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a reader keep, revisit, and export quoted text and notes from EPUB, TXT, and text-layer PDF books, entirely offline.

**Architecture:** One Drift `highlights` table with two nullable locator families: chapter-local offsets for reflowable books and 1-based page segments with PDF-point rectangles for PDFs. A `HighlightController` owns loading and writes; the reader paints reflowable slices through `buildPageSpans` and PDF rectangles through a `pagePaintCallbacks` entry; the existing TOC sheet gains a Notes tab; export is pure formatting plus a share-sheet handoff.

**Tech Stack:** Flutter, Dart, Drift/SQLite, pdfrx 2.4.5, share_plus 13.3, path_provider.

**Spec:** `docs/superpowers/specs/2026-11-09-highlights-quotes-notes-design.md`

## Global Constraints

- Schema version becomes **9**. Migration is forward-only and must preserve books, bookmarks, sessions, collections, and settings.
- One locator family per row: either reflowable (`chapter`, `startOffset`, `endChapter`, `endOffset`) or PDF (`page`, `segments`), never both, never neither.
- Reflowable offsets are **chapter-local UTF-16 code units**. PDF `page` is **1-based**. PDF rects are `[left, top, right, bottom]` in PDF page coordinates with `top > bottom`.
- No new dependencies. Offline only. No account, no network, no sync.
- Highlight colours are a fixed five-entry palette. Light-theme alpha `0.35`, dark/OLED alpha `0.28`.
- Toolbar labels are exactly `Define`, `Copy`, `Share`, `Highlight`, `Note`. Notes tab label is exactly `Notes`.
- All new user-facing strings are English, matching the current app.
- Run `dart format` on touched Dart files before each commit.
- Verification commands: `flutter test <path>` per task; `flutter analyze` and `flutter test` at the end.

## Review Focus

These are the failure modes most likely to bite a reader. Each is pinned by a test in the task that owns the code.

1. **A selection that crosses a chapter boundary** must render on both chapters' pages and jump to the start, not vanish or paint only half. (Task 2, Task 8)
2. **Changing font size, line height, margins, or theme after highlighting** must not move the highlight; offsets are chapter-local, not page- or flat-based. (Task 2, Task 8)
3. **A PDF selection spanning several lines or pages** must highlight every line tightly and stay aligned after zoom and rotation, not paint one large bounding box. (Task 6, Task 9)
4. **Reopening a book or restarting the app** must show the same highlights, with no duplicate rows and no database call per page. (Task 1, Task 5, Task 8)
5. **Removing a book** must delete its highlights and disclose the count before the user confirms; no orphan rows. (Task 12)
6. **The five-button toolbar at 320 dp** must not overflow or hide actions. (Task 7)

---

### Task 1: Schema v9, CRUD, and cascade

**Files:**
- Modify: `lib/db/database.dart`
- Test: `test/database_test.dart`

**Interfaces:**
- Consumes: existing `Books` table, `_newId`-style ids from callers, `NativeDatabase.memory(setup: ...)` in tests.
- Produces:
  - `class Highlights extends Table` with data class `HighlightRow`
  - `Future<void> insertHighlight(HighlightsCompanion highlight)`
  - `Future<List<HighlightRow>> getHighlightsForBook(String bookId)`
  - `Future<void> updateHighlightNote(String id, String note)`
  - `Future<void> updateHighlightColor(String id, int color)`
  - `Future<void> deleteHighlightById(String id)`
  - `Future<int> countHighlightsForBook(String bookId)`
  - cascade inside `deleteBookById`

- [ ] **Step 1: Write the failing database tests**

Add a `group('Highlights', ...)` to `test/database_test.dart`. Use a helper that inserts a book first.

```dart
HighlightsCompanion highlight({
  String id = 'h1',
  String bookId = 'b1',
  int? chapter = 0,
  int? startOffset = 10,
  int? endChapter = 0,
  int? endOffset = 20,
  int? page,
  String? segments,
}) => HighlightsCompanion.insert(
  id: id,
  bookId: bookId,
  text: 'quoted words',
  note: const Value(''),
  color: const Value(0),
  chapter: Value(chapter),
  startOffset: Value(startOffset),
  endChapter: Value(endChapter),
  endOffset: Value(endOffset),
  page: Value(page),
  segments: Value(segments),
  createdAt: 1000,
);
```

Assertions:

- `insert and read highlights in reading order`: insert chapter 1 start 5, chapter 0 start 40, chapter 0 start 10; expect offsets `[10, 40]` in chapter 0 then chapter 1.
- `update note and colour`: call both methods; reread and expect `note == 'new note'`, `color == 3`.
- `delete one highlight`: delete `h1`; expect empty.
- `deleteBookById cascades to highlights`: insert two highlights for `b1` and one for `b2`; delete `b1`; expect `getHighlightsForBook('b1')` empty and `b2` still has one.
- `migration from v8 creates the highlights table`:

```dart
final executor = NativeDatabase.memory(setup: (raw) {
  raw.execute('CREATE TABLE books (id TEXT NOT NULL PRIMARY KEY)');
  raw.userVersion = 8;
});
final migrated = AppDatabase.forTesting(executor);
expect(await migrated.getHighlightsForBook('none'), isEmpty);
final version = await migrated.customSelect('PRAGMA user_version').getSingle();
expect(version.data['user_version'], 9);
expect(await migrated.countHighlightsForBook('none'), 0);
await migrated.close();
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/database_test.dart`
Expected: FAIL — `HighlightsCompanion` / `getHighlightsForBook` are undefined.

- [ ] **Step 3: Add the table, version bump, migration, and methods**

In `lib/db/database.dart`:

- Add `Highlights` with columns `id`, `bookId` (references `Books.id`), `text`, `note` (default `''`), `color` (default `0`), nullable `chapter`, `startOffset`, `endChapter`, `endOffset`, nullable `page`, nullable `segments`, `createdAt`, nullable `updatedAt`. Primary key `{id}`.
- Register `Highlights` in `@DriftDatabase(tables: [...])`.
- Set `schemaVersion` to `9`.
- Add a `hasTable` helper alongside `hasColumn`; in `onUpgrade`, when `from < 9`, create the table if missing and run `CREATE INDEX IF NOT EXISTS idx_highlights_book_id ON highlights (book_id)`.
- Add the six methods. Reading order is `page ASC, chapter ASC, startOffset ASC`. Update methods set `updatedAt` to `DateTime.now().millisecondsSinceEpoch`.
- In `deleteBookById`'s transaction, delete `highlights` for the book before deleting the book row.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/database_test.dart`
Expected: PASS, including the v8 migration test.

- [ ] **Step 5: Commit**

```bash
dart format lib/db/database.dart test/database_test.dart
git add lib/db/database.dart test/database_test.dart
git commit -m "feat(db): add highlights table and v9 migration"
```

---

### Task 2: Locator conversion and clipping helpers

**Files:**
- Create: `lib/utils/highlight_locator.dart`
- Test: `test/highlight_locator_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces:

```dart
({int chapter, int offset}) splitFlatOffset(int flat, List<int> charsBefore);
int flatOffsetFor(int chapter, int offset, List<int> charsBefore);
({int chapter, int startOffset, int endChapter, int endOffset})
    reflowableLocatorFromFlat({required int start, required int end, required List<int> charsBefore});
({int chapter, int start, int end})? clampReflowableLocator({
  required int chapter,
  required int startOffset,
  required int endChapter,
  required int endOffset,
  required int chapterCount,
  required int Function(int chapter) chapterLength,
});
({int start, int end})? clipHighlightToPage({
  required int highlightChapter,
  required int startOffset,
  required int endChapter,
  required int endOffset,
  required int chapter,
  required int pageStart,
  required int pageEnd,
  required int chapterLength,
});
```

- [ ] **Step 1: Write the failing tests**

Create `test/highlight_locator_test.dart` with these cases:

- `splitFlatOffset finds the chapter containing the offset`: `charsBefore = [0, 100, 250]`; `split(0) == (chapter:0, offset:0)`, `split(100) == (chapter:1, offset:0)`, `split(249) == (chapter:2, offset:... )` (250 - 250 = 0).
- `reflowableLocatorFromFlat keeps cross-chapter selections`: start 90, end 110 with the same `charsBefore`; expect `chapter:0, startOffset:90, endChapter:1, endOffset:10`.
- `flatOffsetFor round-trips a locator`.
- `clampReflowableLocator returns null for a missing chapter`: chapter 5 with `chapterCount: 3`.
- `clampReflowableLocator clamps an overlong offset`: chapter 0 length 50, startOffset 80, endOffset 90; expect `(chapter:0, start:50, end:50)` and treat start == end as `null`.
- `clipHighlightToPage clips a highlight that starts before the page`: highlight chapter 0 start 10 end 90, page 0 start 40 end 60; expect `(start:40, end:60)`.
- `clipHighlightToPage returns null for a different chapter`.
- `clipHighlightToPage paints a mid-chapter page of a cross-chapter highlight`: highlight chapter 0 start 10, endChapter 2 end 20; page chapter 1 start 0 end 30; expect `(start:0, end:30)`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/highlight_locator_test.dart`
Expected: FAIL — file not found.

- [ ] **Step 3: Implement the helpers**

Rules:

- `splitFlatOffset` binary-searches the last `i` with `charsBefore[i] <= flat`; empty list returns `(chapter:0, offset:0)`; offset is clamped to `>= 0`.
- `flatOffsetFor` clamps `chapter` into range and returns `charsBefore[chapter] + max(0, offset)`.
- `reflowableLocatorFromFlat` splits `start` and `max(start, end - 1)`, then sets the exclusive end offset using `end`; if the end lands exactly on a later chapter's first character, use that chapter with offset 0.
- `clampReflowableLocator` clamps start/end into the current chapter lengths, orders `endChapter >= chapter`, and returns `null` when the result is empty or the start chapter is out of range.
- `clipHighlightToPage` uses `chapterLength` for open ends on chapters before/after the page chapter, then clips against `pageStart`/`pageEnd`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/highlight_locator_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
dart format lib/utils/highlight_locator.dart test/highlight_locator_test.dart
git add lib/utils/highlight_locator.dart test/highlight_locator_test.dart
git commit -m "feat(highlights): add locator conversion and clipping helpers"
```

---

### Task 3: Service API, validation, and counts

**Files:**
- Modify: `lib/services/library_service.dart`
- Test: `test/highlight_service_test.dart`

**Interfaces:**
- Consumes: Task 1 database methods; `_newId`; `debugAttachDatabase`.
- Produces:

```dart
Future<String> addHighlight({
  required String bookId,
  required String text,
  String note = '',
  int color = 0,
  int? chapter,
  int? startOffset,
  int? endChapter,
  int? endOffset,
  int? page,
  String? segments,
});
Future<List<db.HighlightRow>> getHighlights(String bookId);
Future<void> updateHighlightNote(String id, String note);
Future<void> updateHighlightColor(String id, int color);
Future<void> deleteHighlight(String id);
Future<int> countHighlightsForBook(String bookId);
Future<Map<String, int>> highlightCountsForBooks(Iterable<String> bookIds);
```

- [ ] **Step 1: Write the failing service tests**

Create `test/highlight_service_test.dart`:

```dart
late LibraryService library;
late AppDatabase db;

setUp(() {
  db = AppDatabase.forTesting(NativeDatabase.memory());
  library = LibraryService()..debugAttachDatabase(db);
});
tearDown(() async {
  library.dispose();
  await db.close();
});
```

Insert a book row before adding highlights. Assertions:

- `adds a reflowable highlight and returns its id`: call with chapter/offsets; expect a non-empty id and one row with the same values.
- `adds a PDF highlight with segments`: page 12, segments JSON; expect stored.
- `rejects a row with both locator families`: expect `throwsArgumentError`.
- `rejects a row with no locator family`: expect `throwsArgumentError`.
- `rejects malformed PDF segments`: segments `'{'`; expect `throwsArgumentError`.
- `updates and deletes through the service`.
- `counts highlights per book` and `highlightCountsForBooks omits unknown ids` (or returns 0; pick and assert one).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/highlight_service_test.dart`
Expected: FAIL — methods undefined.

- [ ] **Step 3: Implement the service methods**

Place next to the bookmark block. Validation before insert:

- Reflowable if `chapter != null`; PDF if `page != null`.
- Exactly one family.
- Reflowable requires all four fields, `startOffset >= 0`, `endOffset > 0`, and `endChapter >= chapter`.
- PDF requires `page >= 1`, `segments` decodes to a `List`, and each entry has an `int page` and a `List rects`.
- Throw `ArgumentError` with a short message on failure.

`addHighlight` writes `createdAt` and `notifyListeners()`, returns the id. Counts use the DB methods and return `0` for a missing database or unknown id.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/highlight_service_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
dart format lib/services/library_service.dart test/highlight_service_test.dart
git add lib/services/library_service.dart test/highlight_service_test.dart
git commit -m "feat(highlights): add service API with locator validation"
```

---

### Task 4: Palette and persisted default colour

**Files:**
- Create: `lib/models/highlight_palette.dart`
- Modify: `lib/models/reader_settings.dart`
- Test: `test/highlight_palette_test.dart`, `test/reader_settings_test.dart`

**Interfaces:**
- Consumes: `ReaderSettings.toJson` / `fromJson`.
- Produces:

```dart
const int kHighlightColorCount = 5;
const List<Color> kHighlightColors = [...];
const List<String> kHighlightColorNames = ['Amber', 'Green', 'Blue', 'Pink', 'Purple'];
Color highlightBackground(int index, {required bool dark});
typedef HighlightSlice = ({int start, int end, int color});
```

- [ ] **Step 1: Write the failing tests**

`test/highlight_palette_test.dart`:

- palette and names both have length `kHighlightColorCount` (5).
- `highlightBackground(-1, dark:false)` clamps to index 0.
- `highlightBackground(99, dark:false)` clamps to index 4.
- light alpha is `0.35`, dark alpha is `0.28` (compare `.a` within `0.001`).

Add to `test/reader_settings_test.dart`:

- default `highlightColorIndex` is `0`.
- `toJson`/`fromJson` round-trip index `3`.
- `fromJson({'highlightColorIndex': 99}).highlightColorIndex == 4`.
- `fromJson({'highlightColorIndex': -4}).highlightColorIndex == 0`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/highlight_palette_test.dart test/reader_settings_test.dart`
Expected: FAIL — palette file missing, field missing.

- [ ] **Step 3: Implement the palette and settings field**

Palette values:

```dart
const List<Color> kHighlightColors = [
  Color(0xFFFFD54F), // amber
  Color(0xFF81C784), // green
  Color(0xFF64B5F6), // blue
  Color(0xFFF06292), // pink
  Color(0xFFBA68C8), // purple
];
```

`highlightBackground` clamps the index, returns the colour with alpha `0.35` (light) or `0.28` (dark). Add `int highlightColorIndex = 0` to `ReaderSettings` (constructor, field, `toJson`, `fromJson`, clamped `0..4` with a `0` fallback).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/highlight_palette_test.dart test/reader_settings_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
dart format lib/models/highlight_palette.dart lib/models/reader_settings.dart test/highlight_palette_test.dart test/reader_settings_test.dart
git add lib/models/highlight_palette.dart lib/models/reader_settings.dart test/highlight_palette_test.dart test/reader_settings_test.dart
git commit -m "feat(highlights): add colour palette and persisted default"
```

---

### Task 5: Highlight controller

**Files:**
- Create: `lib/controllers/highlight_controller.dart`
- Test: `test/highlight_controller_test.dart`

**Interfaces:**
- Consumes: Task 2 locator helpers, Task 3 service methods, Task 4 palette.
- Produces:

```dart
class HighlightController extends ChangeNotifier {
  HighlightController({required LibraryService library, required Book book});
  List<db.HighlightRow> get highlights;
  Future<void> load();
  Future<db.HighlightRow?> addReflowable({
    required String text,
    required int start,
    required int end,
    required List<int> charsBefore,
    required int color,
    String note = '',
  });
  Future<db.HighlightRow?> addPdf({
    required String text,
    required int page,
    required String segments,
    required int color,
    String note = '',
  });
  Future<void> updateNote(String id, String note);
  Future<void> updateColor(String id, int color);
  Future<void> delete(String id);
  Future<db.HighlightRow?> restore(db.HighlightRow row);
  List<db.HighlightRow> forChapter(int chapter);
}
```

- [ ] **Step 1: Write the failing controller tests**

Use `LibraryService()..debugAttachDatabase(AppDatabase.forTesting(NativeDatabase.memory()))`, insert one book, then:

- `addReflowable converts flat offsets to chapter-local`: body lengths `[100, 100]`, start 90 end 110; expect the stored row `chapter:0, startOffset:90, endChapter:1, endOffset:10`.
- `addPdf stores page and segments`: page 12, JSON string.
- `load refreshes the list`.
- `forChapter includes a highlight that starts earlier and ends later`: add chapter 0 endChapter 2; `forChapter(1)` contains it; `forChapter(3)` does not.
- `forChapter excludes PDF rows`.
- `updateNote and updateColor persist`.
- `delete removes the row`.
- `restore re-adds the same content after a delete`: delete, restore, expect one row with the same text, note, colour, and locator (the id may differ).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/highlight_controller_test.dart`
Expected: FAIL — file missing.

- [ ] **Step 3: Implement the controller**

`addReflowable` calls `reflowableLocatorFromFlat`; `addPdf` passes through. Both call `library.addHighlight`, then `load()`, then return the newest row whose id matches the returned id (or `null` if the service returned an empty id). `restore` calls `library.addHighlight` with the row's text, note, colour, and locator, accepts a new id, reloads, and returns the restored row so the UI can track the new id. `forChapter` returns rows where `chapter != null`, `chapter <= chapter`, and `endChapter >= chapter`. Every mutation calls `load()` and `notifyListeners()`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/highlight_controller_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
dart format lib/controllers/highlight_controller.dart test/highlight_controller_test.dart
git add lib/controllers/highlight_controller.dart test/highlight_controller_test.dart
git commit -m "feat(highlights): add reader highlight controller"
```

---

### Task 6: PDF segment geometry

**Files:**
- Create: `lib/utils/pdf_highlight_geometry.dart`
- Test: `test/pdf_highlight_geometry_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces:

```dart
class PdfHighlightRect {
  const PdfHighlightRect({required this.left, required this.top, required this.right, required this.bottom});
  final double left, top, right, bottom;
  // value equality on all four fields
}
class PdfHighlightSegment {
  const PdfHighlightSegment({required this.page, required this.rects});
  final int page;
  final List<PdfHighlightRect> rects;
  // value equality on page and rects
}
String encodePdfSegments(List<PdfHighlightSegment> segments);
List<PdfHighlightSegment> decodePdfSegments(String? json);
List<PdfHighlightRect> pdfRectsForPage(String? json, int page);
```

- [ ] **Step 1: Write the failing geometry tests**

Create `test/pdf_highlight_geometry_test.dart`:

- `round-trips segments in order`: pages 12 and 13 with two rects each; `decodePdfSegments(encodePdfSegments(x))` equals `x`.
- `keeps top greater than bottom`: encode a rect with `top: 700, bottom: 688`; expect the decoded values unchanged.
- `invalid JSON returns an empty list`.
- `filters by page`: two pages; `pdfRectsForPage(json, 13)` returns only page 13's rects.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/pdf_highlight_geometry_test.dart`
Expected: FAIL — file missing.

- [ ] **Step 3: Implement the geometry helpers**

JSON shape exactly `[{"page": int, "rects": [[l,t,r,b], ...]}]`. Decode skips malformed entries rather than throwing. Add value equality so the round-trip test compares fields rather than identity.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/pdf_highlight_geometry_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
dart format lib/utils/pdf_highlight_geometry.dart test/pdf_highlight_geometry_test.dart
git add lib/utils/pdf_highlight_geometry.dart test/pdf_highlight_geometry_test.dart
git commit -m "feat(highlights): add PDF segment geometry"
```

---

### Task 7: Toolbar actions and capture for EPUB, TXT, and PDF

**Files:**
- Modify: `lib/widgets/selection_toolbar.dart`
- Modify: `lib/controllers/selection_toolbar.dart`
- Modify: `lib/screens/reader_screen.dart`
- Test: `test/selection_toolbar_test.dart`

**Interfaces:**
- Consumes: Task 3 `addHighlight`, Task 4 palette/settings, Task 5 controller, Task 6 `encodePdfSegments` / `PdfHighlightSegment`.
- Produces:
  - `SelectionToolbar({required VoidCallback onHighlight, required VoidCallback onNote, ...})`
  - `SelectionToolbarOverlay.show(..., required VoidCallback onHighlight, required VoidCallback onNote)`
  - reader methods `_saveReflowableHighlight({String note = ''})`, `_savePdfHighlight({String note = ''})`, `_promptHighlightNote()`

- [ ] **Step 1: Write the failing toolbar tests**

Update `test/selection_toolbar_test.dart`:

- existing tests pass the two new callbacks.
- `shows Highlight and Note for a single word` expects both labels.
- `tapping Highlight calls its callback` using `tester.tap(find.text('Highlight'))`.
- `all five actions fit at 320 dp` sets `tester.view.physicalSize = const Size(320, 640)` and `devicePixelRatio = 1.0`, pumps the toolbar inside a `SizedBox(width: 320)`, and asserts `tester.takeException()` is `null` and all five labels are found.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/selection_toolbar_test.dart`
Expected: FAIL — missing required callbacks / missing labels.

- [ ] **Step 3: Add the toolbar buttons**

- Add `onHighlight` and `onNote` to `SelectionToolbar`; append `Highlight` and `Note` after `Share`.
- Wrap the row in `SingleChildScrollView(scrollDirection: Axis.horizontal)` so a narrow screen scrolls instead of overflowing.

- [ ] **Step 4: Thread the callbacks through the overlay**

- Add the two callbacks to `SelectionToolbarOverlay.show` and pass them to `SelectionToolbar`.
- Keep `dismiss()` called before invoking either callback, matching Copy/Share.
- Change the positioning to inset the toolbar by 8 px on both sides (`Positioned(left: 8, right: 8, top: ...)`) so a wider row cannot run off screen; keep the vertical clamp.

- [ ] **Step 5: Wire reflowable capture and the note dialog**

- Add `late final HighlightController _highlightCtrl;` created in `initState` with the book and `widget.library`, disposed in `dispose`, and `await _highlightCtrl.load()` wherever bookmarks load.
- Extend `_showSelectionToolbar` to accept `onHighlight`/`onNote` and pass them through.
- In `_showSelectionToolbarAt`, pass `onHighlight: () => _saveReflowableHighlight()` and `onNote: _promptHighlightNote`.
- `_saveReflowableHighlight` reads `_selection.start/end`, `_charsBefore`, and `_settings.highlightColorIndex`; calls `_highlightCtrl.addReflowable`; clears the selection; shows the toast `Highlight saved`.
- `_promptHighlightNote` opens an `AlertDialog` with a multiline `TextField`, Cancel and Save; Save calls `_saveReflowableHighlight(note: text)` (or `_savePdfHighlight` when `_isPdf`).

- [ ] **Step 6: Wire PDF capture and suppress the native menu**

- Replace the 50-character gate with capture of any non-empty selection. Store
  `({String text, int page, String segments})? _pendingPdfSelection`; build
  `List<PdfHighlightSegment>` from `enumerateFragmentBoundingRects()` and `bounds`
  for each range, grouping by `pageNumber`, then store `encodePdfSegments(...)`.
  `page` is the first segment's page.
- Show the toolbar with `singleWord: false`, `onHighlight`, and `onNote`.
- Set `buildContextMenu: (context, params) => null` in `PdfViewerParams`.
- Clear `_pendingPdfSelection` when the selection is cleared.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `flutter test test/selection_toolbar_test.dart test/highlight_controller_test.dart`
Expected: PASS. Then run `flutter analyze lib/screens/reader_screen.dart lib/widgets/selection_toolbar.dart lib/controllers/selection_toolbar.dart` and expect no errors.

- [ ] **Step 8: Manual check on a device**

Open an EPUB and a PDF, select text, confirm Define/Copy/Share/Highlight/Note all appear, save a highlight and a note in each format, and confirm no native PDF menu competes.

- [ ] **Step 9: Commit**

```bash
dart format lib/widgets/selection_toolbar.dart lib/controllers/selection_toolbar.dart lib/screens/reader_screen.dart test/selection_toolbar_test.dart
git add lib/widgets/selection_toolbar.dart lib/controllers/selection_toolbar.dart lib/screens/reader_screen.dart test/selection_toolbar_test.dart
git commit -m "feat(highlights): add toolbar actions and capture"
```

---

### Task 8: Paint reflowable highlights

**Files:**
- Modify: `lib/utils/page_spans.dart`
- Modify: `lib/screens/reader_screen.dart`
- Test: `test/page_spans_test.dart`

**Interfaces:**
- Consumes: Task 2 `clipHighlightToPage`, Task 4 `HighlightSlice`/`highlightBackground`, Task 5 `HighlightController`.
- Produces:
  - `buildPageSpans(..., List<HighlightSlice> highlightSlices = const [])`
  - reader method `List<HighlightSlice> _highlightSlicesForPage(int chapter, TextPage page)`

- [ ] **Step 1: Write the failing span tests**

Add to `test/page_spans_test.dart`:

- `paints a highlight background`: one slice `(start:0, end:4, color:0)` over `"word word"`; find a `TextSpan` whose text is `"word"` and whose `style.backgroundColor` equals `highlightBackground(0, dark:false)`. Use a light `ReaderTheme`.
- `selection overrides a highlight`: same slice plus `selectedRange: (start:0, end:4)`; expect the span background to be `theme.selection`.
- `highlight boundaries split the span`: slice `(start:5, end:9)` produces separate spans for `"word "` and `"word"`.
- `a slice outside the page paints nothing`: slice `(start:50, end:60)` on a 9-character page; no span has a highlight background.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/page_spans_test.dart`
Expected: FAIL — unknown named parameter `highlightSlices`.

- [ ] **Step 3: Implement the painting**

In `buildPageSpans`:

- Add the parameter.
- Include the early-return condition when no slices.
- Add slice edges to the cut set.
- After run and match styling, and **before** selection styling, set the background when `segStart >= slice.start && segEnd <= slice.end` using `highlightBackground(slice.color, dark: theme.isDark)`.
- Selection still overrides afterwards.

In the reader:

- `_highlightSlicesForPage(chapter, page)` iterates `_highlightCtrl.forChapter(chapter)`, calls `clipHighlightToPage` with the chapter body length, and returns `(start, end, color)` chapter-local slices.
- Pass the result into `_PageContent` (new field) and into `buildPageSpans`.
- Rebuild when `_highlightCtrl` notifies (`addListener(() => setState(() {}))`) and remove the listener on dispose.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/page_spans_test.dart`
Expected: PASS.

- [ ] **Step 5: Manual check**

Highlight across a page turn and across a chapter boundary; change font size, line height, margins, and theme; confirm the highlight stays on the same words and does not slow paging.

- [ ] **Step 6: Commit**

```bash
dart format lib/utils/page_spans.dart lib/screens/reader_screen.dart test/page_spans_test.dart
git add lib/utils/page_spans.dart lib/screens/reader_screen.dart test/page_spans_test.dart
git commit -m "feat(highlights): paint highlights on reflowable pages"
```

---

### Task 9: Paint PDF highlights

**Files:**
- Modify: `lib/screens/reader_screen.dart`

**Interfaces:**
- Consumes: Task 6 `pdfRectsForPage` / `PdfHighlightRect`; Task 7's stored PDF rows; Task 4 `highlightBackground`; Task 5 controller.
- Produces: a `pagePaintCallbacks` entry on `PdfViewerParams`.

- [ ] **Step 1: Add the paint callback**

No new automated test: page filtering and rect serialization are covered by Task 6, and the draw loop itself is three lines. Keep the tested logic in the helper.

In `_buildPdf`:

- Keep a field `List<db.HighlightRow> _pdfHighlights = const [];` updated from `_highlightCtrl.highlights` whenever the controller notifies, followed by `setState`.
- Add to `PdfViewerParams`:

```dart
pagePaintCallbacks: [
  (canvas, pageRect, page) {
    for (final row in _pdfHighlights) {
      for (final rect in pdfRectsForPage(row.segments, page.pageNumber)) {
        final r = PdfRect(rect.left, rect.top, rect.right, rect.bottom)
            .toRectInDocument(page: page, pageRect: pageRect);
        canvas.drawRect(
          r,
          Paint()..color = highlightBackground(row.color, dark: theme.isDark),
        );
      }
    }
  },
],
```

- The callback reads the current `_pdfHighlights` field; it never queries the database.
- The callback closure is created once per build; `setState` from the controller is what repaints. If pdfrx caches params, key the viewer's `params` on nothing mutable and rely on the field read; do not add/remove the callback.

- [ ] **Step 2: Verify analyzer and the geometry tests**

Run: `flutter analyze lib/screens/reader_screen.dart`
Expected: no errors.

Run: `flutter test test/pdf_highlight_geometry_test.dart`
Expected: PASS.

- [ ] **Step 3: Manual check**

Highlight a multi-line paragraph and a selection spanning two pages; zoom in/out and rotate; confirm line-level rectangles stay aligned and no large empty box is painted.

- [ ] **Step 4: Commit**

```bash
dart format lib/screens/reader_screen.dart
git add lib/screens/reader_screen.dart
git commit -m "feat(highlights): paint PDF highlight segments"
```

---

### Task 10: Notes tab, jump, and PDF outline guard

**Files:**
- Modify: `lib/widgets/toc_sheet.dart`
- Modify: `lib/screens/reader_screen.dart`
- Test: `test/toc_sheet_test.dart`

**Interfaces:**
- Consumes: Task 3/5 list data, Task 4 palette, Task 2 `clampReflowableLocator`/`flatOffsetFor`.
- Produces:

```dart
class HighlightTab {
  const HighlightTab({
    required this.highlights,
    required this.onJump,
    required this.onNoteChanged,
    required this.onColorChanged,
    required this.onDelete,
    required this.onRestore,
    required this.locatorLabel,
    required this.canJump,
    required this.onExport,
  });
  final List<db.HighlightRow> highlights;
  final void Function(db.HighlightRow) onJump;
  final void Function(db.HighlightRow, String note) onNoteChanged;
  final void Function(db.HighlightRow, int color) onColorChanged;
  final void Function(db.HighlightRow) onDelete;
  final Future<db.HighlightRow?> Function(db.HighlightRow) onRestore;
  final String Function(db.HighlightRow) locatorLabel;
  final bool Function(db.HighlightRow) canJump;
  final VoidCallback onExport;
}
```

`TocSheet.show` and `TocSheet.showPdf` gain `required HighlightTab highlightTab`.

- [ ] **Step 1: Write the failing sheet tests**

Update `test/toc_sheet_test.dart` so every existing call passes an empty `HighlightTab`. Add:

- `shows a Notes tab with a count`: one highlight; expect `find.text('Notes 1')`.
- `lists quote text and locator`: expect the quote and `Page 12`.
- `tapping a row calls onJump`.
- `editing a note calls onNoteChanged`: open the row overflow, tap `Edit note`, enter text, Save; expect the callback with the new note.
- `changing colour calls onColorChanged`: tap `Change colour`, tap `Green`; expect index `1`.
- `deleting calls onDelete and Undo calls onRestore`: tap `Delete`; expect `onDelete` and a SnackBar with `Undo`. Tap `Undo`; expect `onRestore` with the same row and the restored row back in the list.
- `an unavailable row shows the fallback label and does not jump`: `canJump` false; expect `Location unavailable`; tapping the row calls nothing.
- `empty state renders`: no highlights; expect `No highlights yet.`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/toc_sheet_test.dart`
Expected: FAIL — `HighlightTab` missing / no Notes tab.

- [ ] **Step 3: Implement the Notes tab UI**

- Add `HighlightTab` and a `_HighlightsList` stateful widget.
- `TabController(length: 3)`.
- PDF tabs: `Outline`, `Bookmarks`, `Notes`; reflowable: `Contents`, `Bookmarks`, `Notes`.
- Row: colour dot, quote (4 lines), note preview, locator, date; overflow menu with the three actions.
- Note dialog, colour dialog (names from `kHighlightColorNames`, check mark on current), delete with a `SnackBar` whose `Undo` action calls `onRestore(row)` and inserts the returned row (with its new id) locally.
- Unavailable rows disable the tap.
- Keep a local `List<db.HighlightRow> _items` so edits and deletes update the open sheet without waiting for the reader to re-open it.

- [ ] **Step 4: Wire the tab into the reader**

- Remove `if (_pdfCtrl.pdfOutline.isEmpty) return;` from `_showTocSheet`; pass an empty outline and let the sheet show `No contents`.
- Build `HighlightTab` with:
  - reflowable `locatorLabel`: `_doc!.chapters[row.chapter].title`, or `Page N` for PDF; return `Location unavailable` when the chapter is out of range.
  - `canJump`: `clampReflowableLocator(...) != null` for reflowable; `row.page != null` for PDF.
  - `onJump`: close the sheet, then `_jumpToPdfPage(row.page!)` or compute `flatOffsetFor(row.chapter, row.startOffset, _charsBefore)` → `_flatIndexForPosition` → `_pageController.jumpToPage`.
  - `onNoteChanged`/`onColorChanged`/`onDelete` calling `_highlightCtrl.updateNote/updateColor/delete`.
  - `onRestore` calling `_highlightCtrl.restore(row)`.
  - `onExport`: Task 11's export sheet. In this task, wire a placeholder that shows a toast `Export coming next`; Task 11 replaces it.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `flutter test test/toc_sheet_test.dart`
Expected: PASS.

- [ ] **Step 6: Manual check**

Open an EPUB and a PDF with no outline; confirm Notes is reachable in both, tap a row jumps correctly, edits persist after closing and reopening the sheet, and Undo restores a deleted highlight.

- [ ] **Step 7: Commit**

```bash
dart format lib/widgets/toc_sheet.dart lib/screens/reader_screen.dart test/toc_sheet_test.dart
git add lib/widgets/toc_sheet.dart lib/screens/reader_screen.dart test/toc_sheet_test.dart
git commit -m "feat(highlights): add Notes tab with jump and editing"
```

---

### Task 11: Markdown and JSON export

**Files:**
- Create: `lib/services/highlight_exporter.dart`
- Modify: `lib/screens/reader_screen.dart`
- Test: `test/highlight_exporter_test.dart`

**Interfaces:**
- Consumes: `Book`, `db.HighlightRow`, Task 10's `HighlightTab.onExport`.
- Produces:

```dart
String highlightsToMarkdown({
  required Book book,
  required List<db.HighlightRow> highlights,
  required String Function(db.HighlightRow) locatorLabel,
  DateTime? exportedAt,
});
String highlightsToJson({
  required Book book,
  required List<db.HighlightRow> highlights,
  DateTime? exportedAt,
});
```

- [ ] **Step 1: Write the failing exporter tests**

Create `test/highlight_exporter_test.dart` with a fixed `exportedAt: DateTime.utc(2026, 11, 9)`:

- `markdown groups by chapter and quotes text`:

```text
# Test Book — Author
_Exported 2026-11-09_

## Chapter One
> quoted words

**Note:** my thought
```

- `markdown uses Page N for PDF locators`.
- `markdown skips highlights with empty text`.
- `json has version, book, date, and locator fields`: decode and expect `version == 1`, `book.title`, `highlights[0].chapter`, `highlights[0].segments`.
- `json round-trips all highlights`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/highlight_exporter_test.dart`
Expected: FAIL — file missing.

- [ ] **Step 3: Implement the exporter and the export menu**

Exporter: pure string building; no Flutter widgets. Markdown groups consecutive rows with the same locator label; JSON encodes nullable fields as `null`.

Reader:

- Replace Task 10's placeholder `onExport` with a modal bottom sheet offering `Markdown` and `JSON`.
- Build the content, write it to `getTemporaryDirectory()` as `"<sanitized title> — highlights.md"` / `.json`, then
  `SharePlus.instance.share(ShareParams(files: [XFile(path)]))`.
- Disable the menu when there are no highlights.
- On share failure, show a toast `Could not export highlights`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/highlight_exporter_test.dart`
Expected: PASS.

- [ ] **Step 5: Manual check**

Export both formats from an EPUB and a PDF, open the files, and confirm the text and locators are correct.

- [ ] **Step 6: Commit**

```bash
dart format lib/services/highlight_exporter.dart lib/screens/reader_screen.dart test/highlight_exporter_test.dart
git add lib/services/highlight_exporter.dart lib/screens/reader_screen.dart test/highlight_exporter_test.dart
git commit -m "feat(highlights): export Markdown and JSON"
```

---

### Task 12: Disclose highlight counts on book removal

**Files:**
- Modify: `lib/screens/library_screen.dart`
- Modify: `lib/services/library_service.dart` (only if `highlightCountsForBooks` is not already implemented)
- Test: `test/library_highlight_removal_test.dart`

**Interfaces:**
- Consumes: Task 3 `countHighlightsForBook` / `highlightCountsForBooks`.
- Produces: remove sheets that include a sentence when the count is non-zero.

- [ ] **Step 1: Write the failing widget test**

Create `test/library_highlight_removal_test.dart` following the setup in `test/library_selection_widget_test.dart`:

- Attach an in-memory DB, insert a book, add two highlights to it.
- Pump `LibraryScreen`.
- Open the book's overflow menu, tap `Move to trash` (or the current remove action), and pump.
- Expect `Also deletes 2 highlights.` in the sheet.
- Repeat for a batch of two books with one highlight each and expect `Also deletes 2 highlights.`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/library_highlight_removal_test.dart`
Expected: FAIL — text not found.

- [ ] **Step 3: Add the count line**

- Make `_showRemoveBookSheet` and `_showRemoveBooksSheet` load counts before opening the sheet (`await` is allowed; the callers already use `unawaited`/`async`).
- Compute `total = await library.countHighlightsForBook(book.id)` or `highlightCountsForBooks(ids)` summed.
- Insert below the title:

```dart
if (count > 0)
  Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Text(
      'Also deletes $count highlight${count == 1 ? '' : 's'}.',
      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
    ),
  ),
```

- Keep the existing Remove/Cancel flow and file-delete checkbox.

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/library_highlight_removal_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
dart format lib/screens/library_screen.dart test/library_highlight_removal_test.dart
git add lib/screens/library_screen.dart test/library_highlight_removal_test.dart
git commit -m "feat(library): disclose highlights deleted with a book"
```

---

## Final Verification

After all tasks are committed:

- [ ] `flutter analyze` — expect no errors or new warnings.
- [ ] `flutter test` — expect the whole suite green.
- [ ] Manual device pass:
  - EPUB: highlight a sentence, add a note, change font size, restart, jump from Notes.
  - TXT: same flow.
  - PDF: multi-line and two-page selection, zoom, rotate, restart, jump.
  - Delete a book with highlights and confirm the count line, then confirm no rows remain.
  - TalkBack: toolbar labels, list rows, colour swatches, note dialog.
- [ ] Confirm the feature works with no network connection.
