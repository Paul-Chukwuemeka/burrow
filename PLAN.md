# Burrow — Post-Review Fix Plan

Generated from code review. Each issue has a checkbox, severity, location, and concrete fix.

## How to Use This Document

When working through items, update the status markers in real time so other agents
(or your future self) always know what's happening:

- `- [ ]` — Not started
- `- [~]` — **In progress** — announce which item you're starting before editing
- `- [x]` — Done (commit hash or PR reference optional but helpful)
- `- [-]` — Skipped (add reason)

**Before starting an item:** Post a message like:
```
Starting item #N: <short description>
```

**While working:** If you hit a blocker or need to deviate from the planned fix,
post an update so the other agent doesn't duplicate work:
```
Item #N update: <what changed / what's blocking>
```

**After completing an item:** Mark it done and commit. Post:
```
Completed item #N — committed as <hash or "locally committed">
```

This keeps the document as a live status board, not just a static plan.

---

## Pre-Ship Blockers

- [x] **1. Fix `applicationId`**
  - **File:** `android/app/build.gradle.kts:1`
  - **What:** `applicationId = "com.example.burrow"` — must be a real package name before any release. Cannot be changed after first Play Store publish.
  - **Fix:** Change to e.g. `com.paulchukwuemeka.burrow`

---

## Major Issues

- [x] **2. O(n×m) bookmark/session restore in `importLibrary`**
  - **File:** `lib/services/library_service.dart:256-278`
  - **What:** For every book imported, iterates ALL bookmarks and ALL sessions in the backup to filter by `bookId`. With 500 books × 2000 bookmarks = 1M iterations.
  - **Fix:** Pre-build `Map<String, List<dynamic>>` keyed by `bookId` before the loop:
    ```dart
    final bookmarksByBook = <String, List<dynamic>>{};
    for (final bm in bookmarksJson) {
      final m = bm as Map<String, dynamic>;
      (bookmarksByBook[m['bookId'] as String] ??= []).add(m);
    }
    // Same pattern for sessionsByBook
    ```
  - **Verify:** Import a backup with 100+ books and time it before/after.

- [x] **3. N+1 and full-table-scan stat queries**
  - **File:** `lib/db/database.dart:258-384`
  - **What:** Every stats method (`getDailyReadingTime`, `getHourlyReadingTime`, `getMonthlyReadingTime`, `getReadingStreak`, `getLongestSessionMs`, `getAverageSessionMs`, `getTodayReadingTimeMs`, `getThisWeekReadingTimeMs`) calls `getAllSessions()` which loads the entire `reading_sessions` table into Dart memory, then filters/aggregates in Dart. `getPerBookStats` compounds this with a per-book `getSessionsForBook` call (N+1).
  - **Fix:** Replace with SQL aggregation queries using Drift's `selectOnly` + `addColumns` + `groupColumns`. At minimum, add date-range `WHERE` clauses so Dart doesn't filter the full table. For `getPerBookStats`, use a single `GROUP BY bookId` query.
  - **Verify:** Seed 5000+ sessions, measure stats screen load time before/after.

- [x] **4. Comic `_flip` uses wrong page count for lazy CBZ**
  - **File:** `lib/screens/reader_screen.dart:2006-2017`
  - **What:** In `_flip`, the comic branch uses `_comicPages.length` to bounds-check the target page. For lazy CBZ, `_comicPages` only contains the current page (length 1), so flipping always fails after page 0. Should use `_comicPageCount` (which reads from the provider).
  - **Fix:** Replace `_comicPages.length` with `_comicPageCount` in the `_flip` comic branch:
    ```dart
    final target = _comicPage + (rtl ? -direction : direction);
    if (target < 0 || target >= _comicPageCount) return;
    ```
  - **Verify:** Open a multi-page CBZ, flip pages forward and backward.

- [x] **5. Sync file I/O on rebuild in PDF reader**
  - **File:** `lib/screens/reader_screen.dart:1337`
  - **What:** `File(_book.path).existsSync()` called inside `build()` on every rebuild. Synchronous file I/O on the UI thread can cause jank.
  - **Fix:** Check once in `initState` and store a `bool _fileExists`. Or check when `_book` changes in `didUpdateWidget`.
  - **Verify:** Open a PDF on a slow device, confirm no frame drops during chrome toggle.

- [x] **6. Silent settings corruption**
  - **File:** `lib/services/library_service.dart:155-159`
  - **What:** `catch (_) {}` silently swallows JSON parse errors for settings. User gets defaults with no feedback.
  - **Fix:** At minimum add `debugPrint('Failed to load settings: $e');`. Consider showing a snackbar on first launch after corruption.
  - **Verify:** Manually corrupt the `burrow.settings.v1` shared prefs key, relaunch, confirm error is logged.

---

## Minor Issues

- [x] **7. Silent legacy migration failure**
  - **File:** `lib/services/library_service.dart:137-139`
  - **What:** Same `catch (_) {}` pattern for legacy SharedPreferences library migration. Corrupted data silently discarded.
  - **Fix:** Add `debugPrint('Legacy library migration failed: $e');`

- [x] **8. Path traversal check too broad**
  - **File:** `lib/services/library_service.dart:260`
  - **What:** `path.contains('..')` rejects paths like `/storage/0/Books/The..Theory/file.epub`. This is a defense-in-depth check on user-supplied backup data, so strictness is a tradeoff — but could reject valid imports.
  - **Fix (judgment call):** Either:
    - (a) Check for `../` (with slashes) instead of bare `..`, OR
    - (b) Keep as-is and document the limitation, OR
    - (c) Check `..` only at path segment boundaries with regex: `RegExp(r'(?<![/\w])\.\.(?![/\w])')`
  - **Verify:** Create a backup with a book in a directory containing `..` in the name, attempt restore.

- [x] **9. CBZ `ComicPageProvider.open` full archive decode**
  - **File:** `lib/services/comic_page_provider.dart:32`
  - **What:** Reads entire CBZ into memory to decode zip structure. For a 500MB CBZ, doubles memory momentarily.
  - **Fix:** Acceptable for v1. Consider adding a size guard or user warning for archives >200MB. Add a TODO comment.

- [x] **10. `_comicPageController` early initialization**
  - **File:** `lib/screens/reader_screen.dart:1720`
  - **What:** `late final PageController _comicPageController` is initialized eagerly with `_comicPages.length` (which is 0 for CBZ at init time). Works by coincidence via `.clamp(0, 0) = 0`.
  - **Fix:** Document the invariant with a comment, or initialize lazily in `_loadComicPages`.

---

## Nit Issues (Low Priority)

- [ ] **11. `bookToCompanion` / `bookToCompanionForUpdate` duplication**
  - **File:** `lib/db/database.dart:500-558`
  - **What:** Two near-identical functions that differ only in `BooksCompanion.insert(...)` vs `BooksCompanion(...)` with `Value()`. Maintenance risk if `Book` fields change.
  - **Fix:** Acceptable tradeoff. No action needed unless a field is added — then update both.

- [x] **12. `Random.secure()` for ID generation**
  - **File:** `lib/services/library_service.dart:636-637`
  - **What:** `Random.secure()` is overkill for local-only IDs. `Random()` is faster.
  - **Fix:** Cosmetic. No action needed.

---

## Review Round 2 — New Issues (from thorough code review)

### Major Issues (Review Round 2)

- [x] **13. `_showGoToPageDialog` uses wrong page count for lazy CBZ**
  - **File:** `lib/screens/reader_screen.dart:2104`
  - **What:** `final maxPage = _isPdf ? _pdfPageCount : (_isComic ? _comicPages.length : _flatPageCount);` — uses `_comicPages.length` (always 1 for lazy CBZ) instead of `_comicPageCount`. The "Go to page" dialog shows "1–1" for multi-page CBZ files.
  - **Fix:** Replace `_comicPages.length` with `_comicPageCount`.
  - **Verify:** Open a multi-page CBZ, tap page label to open Go To Page, confirm page range is correct.

- [x] **14. `getTotalReadingTimeMs` / `getTotalPagesRead` load full session table into Dart**
  - **File:** `lib/db/database.dart:249-267`
  - **What:** Both methods call `getSessionsForBook()` which loads ALL sessions for a book into Dart memory, then iterates to sum.
  - **Fix:** Replace with SQL aggregation.

- [x] **15. `_processMetadataQueue` silently swallows all extraction errors**
  - **File:** `lib/services/library_service.dart:409-461`
  - **What:** Inner and outer catch blocks discard all metadata extraction errors with no logging.
  - **Fix:** Added `debugPrint` for both catch blocks.

- [x] **16. `ReaderScreenState` is 2758 lines with ~40 state variables and ~80 methods** — all 6 controllers wired
  - **File:** `lib/screens/reader_screen.dart:52-2305`
  - **What:** Single state class manages reflowable pagination, PDF viewing, comic viewing, search, bookmarks, sessions, dictionary overlay, settings, chrome visibility, and word selection.
  - **Fix:** Extracted 7 controller files in `lib/controllers/` + `lib/widgets/reader_chrome.dart`:
    - `ReadingSessionManager` — session lifecycle + page flip tracking ✅ wired
    - `DictionaryOverlay` — word selection toolbar + dictionary lookups ✅ wired
    - `ReaderSearchController` — search state, navigation, overlay builder ✅ wired
    - `BookmarkHelper` — bookmark loading, checking, toggling ✅ wired
    - `PdfReaderController` — PDF page state, outline, viewer ✅ wired
    - `ComicReaderController` — comic loading, pagination, prefetch, preview ✅ wired
    - `ReaderChrome` — top/bottom chrome widget (already a separate widget, no wiring needed)
  - **Status:** reader_screen.dart 2758 → 2305 lines (16% reduction). 201 tests pass, zero analyzer issues.

### Minor Issues (Review Round 2)

- [x] **17. `_restoreComicPosition` scroll offset incorrect for vertical comics**
  - **File:** `lib/screens/reader_screen.dart:1526-1528`
  - **What:** `_comicVerticalScrollController!.jumpTo(_comicPage * viewportHeight);` assumes each comic page exactly fills the viewport height.
  - **Fix:** Use saved `_book.lastOffset` instead of recomputing.

- [x] **18. `_restoreComicPosition` called before `_comicVerticalScrollController` is attached**
  - **File:** `lib/screens/reader_screen.dart:1520-1531`
  - **What:** `_restoreComicPosition` is called from `_loadComicPages` but the scroll controller is lazily created in `_buildComicVertical`.
  - **Fix:** Initialize the controller eagerly in `_restoreComicPosition`.

- [x] **19. `deleteBook` and `deleteBookWithFile` are near-identical**
  - **File:** `lib/services/library_service.dart:506-543`
  - **Fix:** Removed `deleteBook`, callers use `deleteBookWithFile(id)`.

- [x] **20. `_generatePdfCoverInBackground` swallows errors without logging**
  - **File:** `lib/services/library_service.dart:501`
  - **Fix:** Added `debugPrint('PDF cover generation failed: $e');`.

- [x] **21. `importLibrary` collection restore silently drops errors**
  - **File:** `lib/services/library_service.dart:305, 318`
  - **Fix:** Added `debugPrint` for both collection restore catch blocks.

- [x] **22. No size limit on backup file import**
  - **File:** `lib/services/library_service.dart:238`
  - **Fix:** Added 100MB file size check before reading.

- [x] **23. Missing index on `Bookmarks.bookId`**
  - **File:** `lib/db/database.dart:51-61`
  - **Fix:** Handled by v6 migration (`idx_bookmarks_book_id`).

- [x] **24. No tests for comic reader, PDF viewer, or scan service**
  - **File:** `test/`
  - **What:** Comic page provider tests added (7 tests). Comic reader widget tests, PDF viewer, and scan service tests still missing.
  - **Fix:** `comic_page_provider_test.dart` added. Widget-level tests deferred.

### Nit Issues (Review Round 2)

- [x] **25. `_comicPageController` disposed via try/catch for non-comic books**
  - **File:** `lib/screens/reader_screen.dart:367-371`
  - **Fix:** Made nullable, initialized in `_loadComicPages`, null-check in `dispose`.

- [x] **26. `_traversalPattern` regex edge case undocumented**
  - **File:** `lib/services/library_service.dart:973`
  - **Fix:** Added comment explaining regex behavior.

- [-] **27. Legacy SharedPreferences key never cleared after migration** — acceptable tradeoff for data safety

---

## Review Round 3 — New Issues (from on-call mindset review)

### Major Issues (Review Round 3)

- [x] **28. `updateBook` unconditionally nulls out fields when caller doesn't pass them**
  - **File:** `lib/services/library_service.dart:562-585`
  - **What:** The doc says "Pass null to leave unchanged," but the implementation always assigns. `book.description = description` sets it to `null` when the caller doesn't pass `description`. Every call to `updateBook(id, title: 'New Title')` silently wipes description, genre, series, ISBN, and all other nullable fields. This is a **data loss bug** — any metadata edit from the edit screen will destroy fields the user didn't explicitly re-enter.
  - **Fix:** Use null-coalescing to preserve existing values:
    ```dart
    book.description = description ?? book.description;
    book.annotation = annotation ?? book.annotation;
    book.genre = genre ?? book.genre;
    book.seriesName = seriesName ?? book.seriesName;
    book.seriesIndex = seriesIndex ?? book.seriesIndex;
    book.publisher = publisher ?? book.publisher;
    book.isbn = isbn ?? book.isbn;
    book.language = language ?? book.language;
    book.review = review ?? book.review;
    book.publicationDate = publicationDate ?? book.publicationDate;
    book.rights = rights ?? book.rights;
    book.type = type ?? book.type;
    book.source = source ?? book.source;
    book.titleSort = titleSort ?? book.titleSort;
    book.authorSort = authorSort ?? book.authorSort;
    ```
  - **Verify:** Edit a book's title in the edit screen, confirm genre/ISBN/description are preserved.

- [x] **29. `importFileFast` theoretical double-add race**
  - **File:** `lib/services/library_service.dart:351-381`
  - **What:** `_pendingImports` is checked then added with no async lock. While Flutter's single-threaded event loop prevents true concurrency, two `importFileFast` calls from different microtasks (e.g., rapid scan + manual import) could both pass the `containsPath` check before either adds to `_pendingImports`. The `finally` block removes it, creating a window for duplicate adds.
  - **Fix:** Move `_pendingImports.add(path)` before the `try` block (it already is). The real risk is that `containsPath` checks `_books` which is mutated by `_books.add(book)` at line 369 inside the `try`. If two calls interleave, both could pass `containsPath` before either does `_books.add`. Add a synchronous guard:
    ```dart
    if (containsPath(path) || _pendingImports.contains(path)) return null;
    _pendingImports.add(path);
    try {
      // ... already correct
    }
    ```
  - **Verdict:** Judgment call — theoretical risk, practically safe due to Flutter event loop. Track for future hardening.

### Minor Issues (Review Round 3)

- [x] **30. `_PillChip` widget duplicated across 5 files**
  - **Files:** `collection_screen.dart`, `author_screen.dart`, `genre_screen.dart`, `series_screen.dart`, `smart_group_screen.dart`
  - **What:** Identical ~50-line widget copy-pasted in 5 files. Any change to its appearance requires editing 5 files.
  - **Fix:** Extract to shared `lib/widgets/pill_chip.dart`.

- [x] **31. Grid layout code duplicated across 6 files**
  - **Files:** `library_screen.dart`, `collection_screen.dart`, `author_screen.dart`, `genre_screen.dart`, `series_screen.dart`, `smart_group_screen.dart`
  - **What:** `maxTileExtent`, `crossSpacing`, `mainSpacing`, `cardPadding`, `textBlock`, `gridPadding` are repeated verbatim.
  - **Fix:** Extract to shared `lib/widgets/book_grid.dart` helper.

- [x] **32. `page_spans_test.dart` broken — 10 compilation errors**
  - **File:** `test/page_spans_test.dart`
  - **What:** Tests call `buildPageSpans()` without the `settings` parameter that was added to the function signature. These tests won't compile — search highlight logic is untested.
  - **Fix:** Add `settings: const ReaderSettings()` to each test call, or generate the missing parameter.

[-] **33. `_pdfFileExists` field is unused in any guard** — false positive; used at line 1334 to show error view
  - **File:** `lib/screens/reader_screen.dart:139`
  - **What:** `late final bool _pdfFileExists = File(_book.path).existsSync();` is computed but never referenced in the build method. Dead code.
  - **Fix:** Remove the field, or use it to show an error view when the file is missing.

- [x] **34. `_WavyProgress` and `_FanInPages` are dead code**
  - **File:** `lib/screens/onboarding_screen.dart:897-1041`
  - **What:** Both widgets are defined (~145 lines total) but never instantiated in any `build` method.
  - **Fix:** Remove, or mark with `TODO` if intended for future use.

### Nit Issues (Review Round 3)

- [x] **35. `use_build_context_synchronously` warnings in `library_screen.dart`**
  - **File:** `lib/screens/library_screen.dart:836, 859, 1296, 1316, 1415, 1435`
  - **What:** 6 info-level analyzer warnings about using `BuildContext` after `await`. These are inside sheet callbacks where the context is still valid (sheet is mounted).
  - **Fix:** Acceptable — suppress with `// ignore:` if noisy, or restructure to check `mounted` before using context.

---

## Coordination — Two-Agent Split

### Round 1+2 Status

| Agent | Issues | Status |
|-------|--------|--------|
| A | #1, #4, #5, #10, #9 | COMPLETE |
| A (round 2) | #13, #17, #18, #25, #24 | COMPLETE |
| B | #6, #7, #8, #2, #12, #3, #11 | COMPLETE |
| B (round 2) | #14, #15, #19, #20, #21, #22, #23, #26, #27 | COMPLETE |

### Round 3 Agent Split

Two agents work in parallel on separate file groups. Each agent works through
their list top-to-bottom. Within a file group, issues are ordered to avoid
line-range conflicts.

#### Agent A — `reader_screen.dart` + test files
Issues: #28 → #32 → #33 → #34

| # | File | Lines | Effort |
|---|------|-------|--------|
| 28 | `lib/services/library_service.dart` | 562-585 | small (data loss fix) |
| 32 | `test/page_spans_test.dart` | all | small |
| 33 | `lib/screens/reader_screen.dart` | 139 | trivial |
| 34 | `lib/screens/onboarding_screen.dart` | 897-1041 | trivial |

#### Agent B — `library_service.dart` + screen dedup
Issues: #29 → #30 → #31 → #35

| # | File | Lines | Effort |
|---|------|-------|--------|
| 29 | `lib/services/library_service.dart` | 351-381 | small (judgment call) |
| 30 | 5 screen files | — | medium (dedup) |
| 31 | 6 screen files | — | medium (dedup) |
| 35 | `lib/screens/library_screen.dart` | 6 locations | trivial |

### Merge point

After both agents finish, run:
```bash
flutter analyze
flutter test
```
Review combined diff together before committing.

---

## Review Round 4 — On-Call Mindset Review

### Major Issues (Review Round 4)

- [x] **36. `deleteBookWithFile` does not cascade — orphaned bookmarks, sessions, collection-links**
  - **File:** `lib/services/library_service.dart:519-541`
  - **What:** `deleteBookWithFile` only calls `_db!.deleteBookById(id)`. Since `PRAGMA foreign_keys` is not enabled (Drift `NativeDatabase` default), the FK constraints on `Bookmarks`, `ReadingSessions`, and `CollectionBooks` are decorative. Orphaned rows accumulate indefinitely, bloating the database. Exported backups include bookmarks/sessions for books that no longer exist. This is silent data corruption.
  - **Fix:** Add cascading deletes before `deleteBookById`:
    ```dart
    if (_db != null) {
      await _db!.customStatement(
        'DELETE FROM bookmarks WHERE bookId = ?', [id]);
      await _db!.customStatement(
        'DELETE FROM reading_sessions WHERE bookId = ?', [id]);
      await _db!.customStatement(
        'DELETE FROM collection_books WHERE bookId = ?', [id]);
      await _db!.deleteBookById(id);
    }
    ```
  - **Verify:** Add a book, create a bookmark for it, delete the book, query bookmarks table — should be empty.

- [x] **37. `_processMetadataQueue` progress counter inflated by skipped books**
  - **File:** `lib/services/library_service.dart:393-485`
  - **What:** `totalToProcess` is set from `_metadataQueue.length` before the loop. When books are skipped (already `metadataComplete` or not found), `completed++` still increments. If you import 10 books and 3 are already complete, the progress starts at "7/10" and jumps to "10/10" at the end. The `MetadataStatus.progress` event fires for skipped books too, making the status bar unreliable.
  - **Fix:** Count only actually-processed books in `completed`, or pre-filter the queue to exclude already-complete books before emitting the `started` event.

- [x] **38. CBZ memory pressure — archive + decoded entries both live in memory**
  - **File:** `lib/services/comic_page_provider.dart:38-68`
  - **What:** Issue #9 was marked complete but only added a TODO comment. The actual problem remains: `ZipDecoder().decodeBytes(bytes)` decompresses all entries into an `Archive` object kept alive for the provider's lifetime. The raw `bytes` `Uint8List` is also retained by the closure. For a 500-page comic this is ~2x the compressed size in memory simultaneously, and the decompressed images persist in the `Archive` until `dispose()`.
  - **Fix (minimum):** After building `pageMetas`, drop the reference to the raw `bytes` (it's a local, so it should be GC'd, but verify the `Archive` doesn't hold it). Long-term: switch to file-backed random-access ZIP reading.
  - **Verify:** Open a 200+ page CBZ and monitor memory via DevTools — should not grow unbounded.

### Minor Issues (Review Round 4)

- [x] **39. `_nonContentRe` does not strip `<style>` tag bodies**
  - **File:** `lib/services/document_parser.dart:1067-1073`
  - **What:** The regex strips `<head>` and `<script>` content but not `<style>`. CSS rule bodies leak into plain text output. E.g. `<style>p { color: red; }</style><p>Text</p>` produces `p { color: red; } Text` instead of `Text`. The test at `document_parser_test.dart` named "drops style and script bodies" expects style content to be dropped — this test may be failing silently or not running.
  - **Fix:** Add `<style>` to `_nonContentRe`:
    ```dart
    static final RegExp _nonContentRe = RegExp(
        r'<!--.*?-->'
        r'|<head\b[^>]*>.*?</head\s*>'
        r'|<style\b[^>]*>.*?</style\s*>'
        r'|<script\b[^>]*>.*?</script\s*>',
        dotAll: true,
        caseSensitive: false,
    );
    ```
  - **Verify:** Run the "drops style and script bodies" test; confirm it passes.

- [x] **40. `importLibrary` silently swallows per-book parse errors**
  - **File:** `lib/services/library_service.dart:296-298`
  - **What:** The `catch (_) { }` at line 296 drops malformed backup entries with no logging. If a backup has a corrupt book entry, the user sees "Restored N books" with no indication entries were skipped.
  - **Fix:** Add `debugPrint('Skipping malformed backup entry: $e');` in the catch block.

- [x] **41. CBR extraction writes all images to temp dir before reading any**
  - **File:** `lib/services/document_parser.dart:823-848`
  - **What:** For CBR files, `Rar.extractRarFile` extracts ALL images to a temp directory before any are read. A 500-page comic writes 500 image files to disk simultaneously. If the app is killed mid-parse, temp files leak. Also blocks the isolate for the full extraction time.
  - **Fix:** Consider lazy extraction (read from RAR on demand) similar to CBZ's `ComicPageProvider`. Or use a unique temp dir per file to avoid collision with concurrent extractions.
  - **Verify:** Open a large CBR file, confirm temp dir is cleaned up after parse.

---

## Round 5 Issues

- [x] **42. PdfTextSearcher listener accumulates on search toggle**
  - **File:** `lib/controllers/search_controller.dart:102-117` and `lib/screens/reader_screen.dart:702-706`
  - **What:** `toggleSearch()` nulls `_pdfSearcher` without removing the listener added at `reader_screen.dart:705`. Each open/close cycle adds a new listener to a new `PdfTextSearcher` without cleaning up the old one. Leaks the `PdfTextSearcher` and its `PdfViewerController` reference.
  - **Fix:** Remove listener in `toggleSearch` before nulling `_pdfSearcher`, or move listener management into the controller (preferred — controller should own its own listeners).

- [x] **43. DictionaryOverlay captures stale theme and BuildContext**
  - **File:** `lib/controllers/dictionary_overlay.dart:12-18` and `lib/screens/reader_screen.dart:910-914`
  - **What:** `DictionaryOverlay` stores `BuildContext context` and `ReaderTheme theme` at construction time via `??=`. The overlay is never recreated. On theme change (sepia → dark), the toolbar renders with old colors. Also, `Overlay.of(context)` with a captured context is fragile if the overlay outlives the State.
  - **Fix:** Pass `themeBuilder: () => _settings.colors` instead of snapshot, or reset `_dictOverlay = null` in `_onSettingsChanged()` so it's recreated on next use.

- [x] **44. Dead controller methods — `ComicReaderController.onPageChanged` and `onVerticalScroll`**
  - **File:** `lib/controllers/comic_controller.dart:113-148`
  - **What:** Controller has `onPageChanged()` and `onVerticalScroll()` that call `library.savePosition()`, but `reader_screen.dart:1147-1156` and `1199-1217` duplicate this logic inline without calling the controller methods. Dead code. The controller's `onVerticalScroll` also uses `MediaQueryData.fromView(platformDispatcher.views.first)` which bypasses text scaling.
  - **Fix:** Remove dead methods from controller, or have `reader_screen.dart` delegate to them.

- [x] **45. `_dictOverlay` theme not refreshed on settings change**
  - **File:** `lib/screens/reader_screen.dart:910`
  - **What:** `_dictOverlay` is created with `??=` and never recreated. When theme changes via `SettingsSheet`, the overlay still uses the old theme. Follow-on to #43.
  - **Fix:** Reset `_dictOverlay = null` in `_onSettingsChanged()` so it's recreated with the new theme on next use.

- [x] **46. `ReaderSearchController.searchOpen` is not encapsulated**
  - **File:** `lib/controllers/search_controller.dart:15`
  - **What:** `searchOpen` is a public mutable `bool`. Any code can set it without calling `notifyListeners()`, causing UI desync. Currently safe because all mutations go through `toggleSearch()`, but fragile for future changes.
  - **Fix:** Make private with getter, ensure all mutations go through `toggleSearch()`.

---

## Coordination — Round 5 Agent Split

### Agent A — Search controller lifecycle

Issues: #42 → #46

| # | File | Effort |
|---|------|--------|
| 42 | `lib/controllers/search_controller.dart`, `lib/screens/reader_screen.dart` | small (listener lifecycle) |
| 46 | `lib/controllers/search_controller.dart` | trivial (encapsulate field) |

### Agent B — DictionaryOverlay lifecycle + comic dead code

Issues: #43 → #44 → #45

| # | File | Effort |
|---|------|--------|
| 43 | `lib/controllers/dictionary_overlay.dart`, `lib/screens/reader_screen.dart` | small (theme callback) |
| 44 | `lib/controllers/comic_controller.dart`, `lib/screens/reader_screen.dart` | small (remove dead code) |
| 45 | `lib/screens/reader_screen.dart` | trivial (null reset) |

### Merge point

After both agents finish, run:
```bash
flutter analyze
flutter test
```
Review combined diff together before committing.

### Agent A — `library_service.dart` metadata + `document_parser.dart` CSS

Issues: #37 → #39

| # | File | Lines | Effort |
|---|------|-------|--------|
| 37 | `lib/services/library_service.dart` | 393-485 | small (progress counter) |
| 39 | `lib/services/document_parser.dart` | 1067-1073 | small (regex fix) |

### Agent B — `library_service.dart` deletes + imports + CBR

Issues: #36 → #40 → #41

| # | File | Lines | Effort |
|---|------|-------|--------|
| 36 | `lib/services/library_service.dart` | 519-541 | small (cascade deletes) |
| 40 | `lib/services/library_service.dart` | 296-298 | trivial (add debugPrint) |
| 41 | `lib/services/document_parser.dart` | 823-848 | medium (CBR temp dir) |

### Merge point

After both agents finish, run:
```bash
flutter analyze
flutter test
```
Review combined diff together before committing.

---

## Review Round 6 — On-Call Mindset Review

### Major Issues (Review Round 6)

- [x] **47. `_loadStats` fetches `getAllSessions()` AND `getPerBookStats()` — redundant full-table load**
  - **File:** `lib/screens/stats_screen.dart:49-58`
  - **What:** `_loadStats` calls `getAllSessions()` (loads entire `reading_sessions` table into Dart), then manually sums `totalTime` and `totalPages` in a Dart loop (lines 60-65). It ALSO calls `getPerBookStats()` which runs a `GROUP BY bookId` SQL query with the same totals. This is a redundant full-table load + O(n) Dart re-aggregation. For users with thousands of sessions, this wastes memory and CPU. The `getPerBookStats` results already contain `totalTimeMs`, `totalPages`, and `sessionCount` per book.
  - **Fix:** Replace `getAllSessions` + Dart loop with totals derived from `getPerBookStats`:
    ```dart
    final perBookStats = await widget.library.getPerBookStats();
    var totalTime = 0;
    var totalPages = 0;
    var totalSessions = 0;
    for (final s in perBookStats) {
      totalTime += s.totalTimeMs;
      totalPages += s.totalPages;
      totalSessions += s.sessionCount;
    }
    ```
  - **Verify:** Open Stats screen with 5000+ sessions, measure memory and load time before/after.

### Minor Issues (Review Round 6)

- [x] **48. `ReadingSessionManager.endSession` silently swallows DB errors**
  - **File:** `lib/controllers/reading_session.dart:50-59`
  - **What:** `endSession` awaits `library.endSession()` but has no try/catch. If the DB write fails (e.g., DB closed during app shutdown), the error propagates unhandled into `dispose()` via `unawaited(endSession())`, and the session data is silently lost with no logging.
  - **Fix:** Wrap the await in try/catch with `debugPrint`:
    ```dart
    try {
      await library.endSession(sid, pages: pages);
    } catch (e) {
      debugPrint('Failed to end session $sid: $e');
    }
    ```

- [x] **49. `importFileFast` doesn't rollback `_books.add` on DB insert failure**
  - **File:** `lib/services/library_service.dart:351-383`
  - **What:** `_books.add(book)` at line 371 executes before `insertBook` at line 372. If `insertBook` throws, the `finally` block removes the path from `_pendingImports`, but the book remains in `_books`. The book appears in the library with no DB record. On next app launch it won't exist (DB is source of truth), but during the current session it shows as a ghost entry with no metadata.
  - **Fix:** Add a rollback in a catch block before `finally`:
    ```dart
    } catch (e) {
      _books.removeWhere((b) => b.id == book.id);
      rethrow;
    } finally {
      _pendingImports.remove(path);
    }
    ```

- [x] **50. `_processMetadataQueue` inner null/complete check is redundant after pre-filter**
  - **File:** `lib/services/library_service.dart:411-416`
  - **What:** The pre-filter at lines 395-398 already removes books where `book == null || book.metadataComplete`. The inner check at line 414 does the same. If a book is deleted between pre-filter and processing, the inner `continue` skips it without incrementing `completed`, causing the progress bar to stall at N-1/N.
  - **Fix:** Either remove the inner check (pre-filter is sufficient since worker is single-threaded), or increment `completed` before the inner `continue`.

- [x] **51. `_saveCover` orphaned files on app kill**
  - **File:** `lib/services/library_service.dart:635-647`
  - **What:** If the app is killed between `_saveCover` writing a file and `updateBook` persisting the path, the cover file is orphaned on disk with no DB reference. Over time, repeated interrupted imports accumulate unreferenced cover files.
  - **Fix:** Add a cleanup scan in `LibraryService.load()` that removes cover files not referenced by any book's `coverPath`. Or document as known limitation.

- [x] **52. `PdfReaderController.dispose` doesn't remove listener from `PdfViewerController`**
  - **File:** `lib/controllers/pdf_controller.dart:65-70`
  - **What:** `reader_screen.dart:189` adds `_pdfCtrl.onPdfViewChanged` as a listener to `_pdfCtrl.pdfController`. `dispose()` only nulls `pdfSearcher` — it never calls `pdfController.removeListener(onPdfViewChanged)`. Since `pdfController` is a field of `PdfReaderController`, they share lifecycle and the dangling listener won't fire after GC. But it's a correctness gap for future refactoring.
  - **Fix:** Add `pdfController.removeListener(onPdfViewChanged)` in `dispose()`.

### Nit Issues (Review Round 6)

- [x] **53. `_initSearch` called redundantly on every `_submitSearch`**
  - **File:** `lib/screens/reader_screen.dart:717-719`
  - **What:** `_submitSearch` calls `_initSearch()` every time. For reflowable books, `setChapters` has `if (_search != null) return` — a no-op after first call. Works, but the guard makes it unclear whether `_initSearch` is idempotent by design or by accident.
  - **Fix:** Call `_initSearch` once on first search open, or remove the guard and make it idempotent by design.

- [x] **54. `_showGoToPageDialog` has duplicated page-navigation logic**
  - **File:** `lib/screens/reader_screen.dart:1674-1689` and `1698-1713`
  - **What:** The `onSubmitted` callback and the 'Go' button's `onPressed` contain identical page-navigation logic. If one is updated and the other isn't, they diverge.
  - **Fix:** Extract to a local function `_goToPage(int page)`.

---

## Coordination — Round 6 Agent Split

### Agent A — Stats screen + session error handling

Issues: #47 → #48 → #49

| # | File | Effort |
|---|------|--------|
| 47 | `lib/screens/stats_screen.dart` | small (remove redundant getAllSessions) |
| 48 | `lib/controllers/reading_session.dart` | trivial (add try/catch) |
| 49 | `lib/services/library_service.dart` | small (add rollback) |

### Agent B — Metadata queue + cover cleanup + PDF controller

Issues: #50 → #51 → #52

| # | File | Effort |
|---|------|--------|
| 50 | `lib/services/library_service.dart` | trivial (remove redundant check) |
| 51 | `lib/services/library_service.dart` | small (add cleanup scan) |
| 52 | `lib/controllers/pdf_controller.dart` | trivial (remove listener) |

### Merge point

After both agents finish, run:
```bash
flutter analyze
flutter test
```
Review combined diff together before committing.

---

## Review Round 7 — On-Call Mindset Review

### Major Issues (Review Round 7)

- [x] **55. `_cleanupOrphanedCovers` is dead code — never runs**
  - **File:** `lib/services/library_service.dart:170-171` (call site) and `665-681` (implementation)
  - **What:** `load()` calls `_cleanupOrphanedCovers()` at line 171. At this point, `_coversDir` is always `null` — it's only initialized in `_ensureCoversDir()` (line 658), which is called from `_saveCover()` (line 643). The cleanup method checks `if (dir == null || !dir.existsSync()) return;` and exits immediately. The orphaned cover cleanup from #51 never executes.
  - **Failure scenario:** User imports 50 books, the app is killed mid-import 10 times. 10 orphaned cover files accumulate on disk forever. The cleanup function exists but is a no-op.
  - **Fix:** Initialize the covers directory before calling cleanup. Either make `_cleanupOrphanedCovers` async and call `_ensureCoversDir()` internally, or use `_ensureCoversDir().then((_) => _cleanupOrphanedCovers())` at the call site.

### Nit Issues (Review Round 7)

- [x] **56. `_showGoToPageDialog` uses `Navigator.of(context)` instead of `Navigator.of(ctx)`**
  - **File:** `lib/screens/reader_screen.dart:1652`
  - **What:** The `goToPage` function does `Navigator.of(context).pop()` using the State's context, not the dialog's builder context `ctx`. Both resolve to the same Navigator (dialog is pushed onto the same navigator), so this works. But it's less precise than the original `Navigator.of(ctx).pop()` — if the dialog were ever shown on a nested navigator, this would pop the wrong route.
  - **Fix:** Change to `Navigator.of(ctx).pop()`. Since `goToPage` is defined outside the `builder` callback, it needs access to `ctx`. Either pass `ctx` as a parameter or move the function inside the builder.

[-] **57. `deleteBookWithFile` removes book from `_books` before DB cascade deletes** — acceptable; UI responsiveness priority, local SQLite failures extremely rare
  - **File:** `lib/services/library_service.dart:530-559`
  - **What:** `_books.remove(book)` at line 533 happens before the DB deletes at lines 550-557. If any DB delete fails, the book is gone from memory but orphaned rows remain in the database. Judgment call — current order ensures UI updates immediately, and DB failures on local SQLite are extremely rare. But the inverse order would be more defensive.
  - **Fix (judgment call):** Either leave as-is (UI responsiveness priority) or swap order to DB deletes first, then `_books.remove`.

---

## Coordination — Round 7 Agent Split

### Agent A — Single fix

Issues: #55

| # | File | Effort |
|---|------|--------|
| 55 | `lib/services/library_service.dart` | small (fix _coversDir initialization) |

### Agent B — Nits (optional, low priority)

Issues: #56 → #57

| # | File | Effort |
|---|------|--------|
| 56 | `lib/screens/reader_screen.dart` | trivial (pass ctx to goToPage) |
| 57 | `lib/services/library_service.dart` | judgment call (reorder deletes) |

### Merge point

After both agents finish, run:
```bash
flutter analyze
flutter test
```
Review combined diff together before committing.

---

## Review Round 8 — Crash Recovery Review (f80161a)

### Major Issues (Review Round 8)

- [-] **58. Recovery path in `main.dart` destroys ALL SharedPreferences — user loses all settings**
  - **File:** `lib/main.dart:44-45`
  - **What:** When `library.load()` fails, the recovery path calls `await prefs.clear()`. This wipes EVERYTHING — `ReaderSettings`, `onboardingComplete`, `libraryLayout`. User loses all customizations and must redo onboarding.
  - **Failure scenario:** User has customized reading experience. A SharedPreferences corruption (possible on Android force-close) triggers recovery. All settings lost.
  - **Fix:** Only clear library-specific keys:
    ```dart
    await prefs.remove('burrow.library.v1');      // legacy library
    await prefs.remove('burrow.library.layout.v1'); // layout
    ```

### Minor Issues (Review Round 8)

- [x] **59. `database.dart` migration catch swallows errors — leaves DB in partial state**
  - **File:** `lib/db/database.dart:163-164`
  - **What:** The `onUpgrade` catch block only does `debugPrint`. If a migration step fails, DB is left partially migrated. Drift's `schemaVersion` still set to 6, so migration won't retry. Queries on missing columns crash.
  - **Failure scenario:** User upgrades from v3 to v6. Step `from < 4` fails halfway. Some v4 columns exist, others don't.
  - **Fix:** Re-throw after logging so `main.dart` recovery handles it, or delete the DB and rethrow.

### Nit Issues (Review Round 8)

- [-] **60. `main.dart` recovery doesn't verify retry succeeded**
  - **File:** `lib/main.dart:49-53`
  - **What:** If retry also fails, `library` is a fresh `LibraryService()` with no data. App runs empty with no explanation. Acceptable but user sees blank screen.
  - **Fix (optional):** Show a snackbar or error view if retry fails.

---

## Coordination — Round 8 Agent Split

### Agent A — main.dart recovery path

Issues: #58, #60

| # | File | Effort |
|---|------|--------|
| 58 | `lib/main.dart` | small (selective prefs clear) |
| 60 | `lib/main.dart` | trivial (optional) |

### Agent B — database.dart migration

Issues: #59

| # | File | Effort |
|---|------|--------|
| 59 | `lib/db/database.dart` | small (rethrow or delete+retry) |

### Merge point

After both agents finish, run:
```bash
flutter analyze
flutter test
```
Review combined diff together before committing.

---

## Review Round 9 — Library Screen & Search Review

### Major Issues (Review Round 9)

- [x] **61. `_onLibraryChanged` only rebuilds on layout change — all other mutations invisible**
  - **File:** `lib/screens/library_screen.dart:118-125`
  - **What:** The `LibraryService` listener only calls `setState` when the layout mode changes. Book deletion, collection changes, reading progress updates, and cover generation all call `notifyListeners()` but are silently dropped. The library screen doesn't update.
  - **Failure scenario:** User deletes a book. Book removed from `_books`, `notifyListeners()` fires. `_onLibraryChanged` doesn't rebuild (layout unchanged). Deleted book still appears until navigation.
  - **Fix:** Always call `setState` in `_onLibraryChanged` and invalidate `_visibleBooks` cache:
    ```dart
    void _onLibraryChanged() {
      if (!mounted) return;
      final saved = widget.library.libraryLayout;
      final newLayout = saved == 'list' ? _LayoutMode.list : _LayoutMode.grid;
      _cacheKey = null;
      setState(() => _layout = newLayout);
    }
    ```

- [x] **62. Metadata worker permanently stuck after stream disposal**
  - **File:** `lib/services/library_service.dart:394-496`
  - **What:** `_processMetadataQueue` is async but called without `await`. `_metadataStatusController.add()` at line 424 is outside the try block. If `dispose()` closes the stream controller, `.add()` throws `StateError`. `_metadataWorkerRunning` stays `true` forever — no future metadata extraction runs.
  - **Failure scenario:** User imports books, metadata extraction starts, user navigates away. Stream controller closes. Next `.add()` throws. Worker permanently blocked.
  - **Fix:** Wrap while loop body in try/finally to ensure `_metadataWorkerRunning = false` always executes.

- [x] **63. Book search scan permanently stalls after rapid typing**
  - **File:** `lib/services/book_search.dart:89-101`
  - **What:** Race condition between `_startScan` (checks `_running`) and `_scanIncrementally` (sets `_running = false` on query change). When user types quickly, old scan exits, new scan's `_startScan` already returned because `_running` was still `true`. Nobody restarts scan for new query.
  - **Failure scenario:** User types "the", then "theory" quickly. Search results stale/empty until user clears and retypes.
  - **Fix:** In `_scanIncrementally`, call `_startScan()` when exiting due to query change:
    ```dart
    if (_lastQuery != _query) {
      _running = false;
      _startScan();
      return;
    }
    ```

### Minor Issues (Review Round 9)

- [x] **64. `_visibleBooks` cache not invalidated on library changes**
  - **File:** `lib/screens/library_screen.dart:164`
  - **What:** Cache key uses `books.length`. If metadata changes without count change, sorted order is stale.
  - **Fix:** Clear `_cacheKey` in `_onLibraryChanged` (combined with #61 fix).

- [x] **65. `deleteBookWithFile` DB operations not transactional**
  - **File:** `lib/services/library_service.dart:550-558`
  - **What:** Four separate `customStatement` calls. If any fails mid-way, DB is left inconsistent.
  - **Fix:** Wrap in `_db!.transaction()`.

- [x] **66. Synchronous file I/O in `_showBookDetailsSheet`**
  - **File:** `lib/screens/library_screen.dart:608-609`
  - **What:** `existsSync()` and `lengthSync()` block UI thread on slow storage.
  - **Fix:** Compute file size asynchronously before showing sheet.

- [x] **67. `_CollectionPickerTile` recreates `FutureBuilder` futures on rebuild**
  - **File:** `lib/screens/library_screen.dart:762`
  - **What:** Passing `Future<bool>` to `StatelessWidget`. On `setSheetState`, every tile's `FutureBuilder` restarts.
  - **Fix:** Resolve eagerly and pass `bool`, or make tile a `StatefulWidget`.

- [x] **68. EPUB parsing has no file size guard**
  - **File:** `lib/services/document_parser.dart:134-141`
  - **What:** No size check before `readAsBytes()`. Large EPUBs can OOM the isolate.
  - **Fix:** Add file length check (100MB limit like `importLibrary`).

### Nit Issues (Review Round 9)

- [ ] **69. `format` parameter in `parse()` is dead code**
  - **File:** `lib/services/document_parser.dart:108-109`
  - **What:** `parse()` accepts `format` but `_parseIsolate` ignores it, re-deriving from extension.
  - **Fix (optional):** Pass format into isolate or remove from public API.

- [ ] **70. `_naturalCompareImpl` leading-zero edge case**
  - **File:** `lib/services/document_parser.dart:931`
  - **What:** "01" sorts before "1" due to character comparison after numeric equality.
  - **Fix (optional):** Skip character comparison after digit run with `continue`.

- [ ] **71. `_mergeCssStyles` mutates list during iteration**
  - **File:** `lib/services/document_parser.dart:1262-1298`
  - **What:** `runs.removeAt`/`insert` during for loop. Works due to careful index management but fragile.
  - **Fix (optional):** Build new list instead of mutating in place.

---

## Coordination — Round 9 Agent Split

### Agent A — Library screen listener + cache

Issues: #61, #64, #66, #67

| # | File | Effort |
|---|------|--------|
| 61 | `lib/screens/library_screen.dart` | small (listener always setState) |
| 64 | `lib/screens/library_screen.dart` | trivial (clear cache in listener) |
| 66 | `lib/screens/library_screen.dart` | small (async file size) |
| 67 | `lib/screens/library_screen.dart` | small (resolve eagerly or StatefulWidget) |

### Agent B — Service layer fixes

Issues: #62, #63, #65, #68

| # | File | Effort |
|---|------|--------|
| 62 | `lib/services/library_service.dart` | small (try/finally in worker) |
| 63 | `lib/services/book_search.dart` | small (restart scan on query change) |
| 65 | `lib/services/library_service.dart` | small (wrap in transaction) |
| 68 | `lib/services/document_parser.dart` | trivial (add size check) |

### Merge point

After both agents finish, run:
```bash
flutter analyze
flutter test
```
Review combined diff together before committing.

---

## Feature: EPUB Image Sizing from CSS

### Background

The EPUB parser already resolves CSS rules against DOM elements, including `<img>` tags. The `ResolvedCssRule.properties` map already contains `width`, `height`, `max-width`, etc. when present in the EPUB's stylesheets. However, `propsToCssStyle` currently discards all image-sizing properties — only text properties are mapped. Images are sized purely from intrinsic pixel dimensions (PNG/JPEG headers), capped at 150px height for inline images.

**Image size info IS available from the CSS — it's just being thrown away.**

### CSS Priority Chain

```
CSS width/height (from stylesheet)
  → HTML width/height attributes (from <img> tag)
    → OPF manifest width/height (from <item>)
      → Intrinsic pixel dimensions (from PNG/JPEG headers)
```

`max-width`/`max-height` from CSS are applied as caps on the final size.
Percentage values (e.g., `width: 50%`) are relative to page content width.

### Implementation

- [x] **72. Extend `CssStyle` with image-sizing fields**
  - **File:** `lib/models/css_style.dart`
  - **What:** Add `width`, `height`, `maxWidth`, `maxHeight` fields (all `double?`). Update `merge()` and `isEmpty`.

- [x] **73. Map CSS image-sizing properties in `propsToCssStyle`**
  - **File:** `lib/services/epub_css_parser.dart:223`
  - **What:** Parse `width`, `height`, `max-width`, `max-height` from the raw properties map. Support CSS units: `px` (default), `em`/`rem` (×16), `pt` (×1.333), `%` (relative to renderWidth). Reuse existing `_parseLength` helper.

- [x] **74. Add `CssStyle?` field to `ImageRun`**
  - **File:** `lib/models/style_run.dart:50`
  - **What:** Add `this.css` optional field to `ImageRun`. This holds the CSS-derived sizing rules matched to the `<img>` element.

- [x] **75. Apply CSS rules to images during EPUB parsing**
  - **File:** `lib/services/document_parser.dart` (in `parseEpubBytes`, after CSS rules are resolved)
  - **What:** After `EpubCssParser` resolves rules, iterate `ImageRun` objects and match CSS rules to their corresponding `<img>` DOM elements. Merge matched `CssStyle` into `ImageRun.css`.

- [x] **76. Update `ImageRun.renderedSize()` to use CSS dimensions**
  - **File:** `lib/models/style_run.dart:87`
  - **What:** When `css` is non-null, use CSS `width`/`height` as the primary size. Apply `maxWidth`/`maxHeight` as caps. Fall back to intrinsic dimensions when CSS values are absent. Handle `%` values relative to `renderWidth`.

- [x] **77. Read `width`/`height` HTML attributes from `<img>` tags**
  - **File:** `lib/services/document_parser.dart:1197`
  - **What:** In the `<img>` tag handler, read `width` and `height` attributes. Pass to `_RichTextBuilder.image()` as fallback dimensions.

- [x] **78. Read `width`/`height` from OPF `<item>` manifest**
  - **File:** `lib/services/document_parser.dart:355`
  - **What:** In OPF manifest parsing, read `width`/`height` attributes from `<item>` elements for images. Store in a lookup map. Use as fallback.

---

## Coordination — Image Sizing Agent Split

### Agent A — Model + CSS wiring

Issues: #72, #73, #74, #75

| # | File | Effort |
|---|------|--------|
| 72 | `lib/models/css_style.dart` | small (add 4 fields, update merge/isEmpty) |
| 73 | `lib/services/epub_css_parser.dart` | small (map 4 CSS properties) |
| 74 | `lib/models/style_run.dart` | trivial (add `css` field) |
| 75 | `lib/services/document_parser.dart` | medium (wire CSS rules to ImageRun) |

### Agent B — Rendering + fallbacks

Issues: #76, #77, #78

| # | File | Effort |
|---|------|--------|
| 76 | `lib/models/style_run.dart` | small (update renderedSize logic) |
| 77 | `lib/services/document_parser.dart` | trivial (read HTML width/height) |
| 78 | `lib/services/document_parser.dart` | small (read OPF width/height) |

### Merge point

After both agents finish, run:
```bash
flutter analyze
flutter test
```
Review combined diff together before committing.

---

## Performance: EPUB Open Speed Optimizations

### Problem

EPUBs take 1.5–10 seconds to open. Three major bottlenecks:
1. CSS stylesheet compiled from scratch per chapter (50 chapters = 50 identical compilations)
2. Fonts loaded sequentially on main thread
3. Full-book pagination before first page shows

### Implementation

- [x] **79. Compile CSS once, query per chapter**
  - **File:** `lib/services/epub_css_parser.dart:51-84`
  - **What:** Move `css.compile(combinedCss)` outside the per-chapter loop. Compile once, query each chapter's DOM with pre-compiled rules.

- [x] **80. Parallel font loading**
  - **File:** `lib/services/epub_css_parser.dart:389-404`
  - **What:** Replace sequential `await fontLoader.load()` with `Future.wait()`.

[-] **81. Lazy pagination — show reader after first chapters** — already implemented via `_bgNextBatch`/`_lazyRunning` system
  - **File:** `lib/screens/reader_screen.dart:1448-1525`
  - **What:** Paginate first 2-3 chapters eagerly, show reader immediately, paginate rest in background.

- [x] **82. Cache parsed ParsedDocument to disk**
  - **File:** `lib/services/document_parser.dart`, `lib/screens/reader_screen.dart:209-236`
  - **What:** Serialize chapter text/runs/images to disk cache. Load from cache on subsequent opens. Cache key: book ID + file mtime.

[-] **83. Background image decoding** — Flutter already decodes images lazily during widget build; pre-decoding in isolate requires `image` package + `dart:ui` conversion, marginal benefit
  - **File:** `lib/services/document_parser.dart` (in `_parseIsolate`), `lib/models/style_run.dart`
  - **What:** Decode images in background isolate during parsing. Store decoded pixel data so main thread doesn't decode during widget build.

---

## Coordination — Performance Agent Split

### Agent A — CSS optimization + font parallelism

Issues: #79, #80

| # | File | Effort |
|---|------|--------|
| 79 | `lib/services/epub_css_parser.dart` | medium (restructure compile loop) |
| 80 | `lib/services/epub_css_parser.dart` | trivial (Future.wait) |

### Agent B — Pagination + caching + image decoding

Issues: #81, #82, #83

| # | File | Effort |
|---|------|--------|
| 81 | `lib/screens/reader_screen.dart` | medium (chunked early show) |
| 82 | `lib/services/document_parser.dart` + `reader_screen.dart` | medium (cache) |
| 83 | `lib/services/document_parser.dart` + `lib/models/style_run.dart` | medium (decode in isolate) |

### Merge point

After both agents finish, run:
```bash
flutter analyze
flutter test
```
Review combined diff together before committing.

---

## Library Performance Fixes (Round 10)

| # | Severity | File | Issue | Status |
|---|----------|------|-------|--------|
| 84 | Blocker | `lib/widgets/book_cover.dart:38` | `Image.file()` with no `cacheWidth`/`cacheHeight` — full-res bitmaps in memory | [x] |
| 85 | Major | `lib/widgets/book_card.dart:61,174` | Double `Clip.antiAlias` per card — redundant offscreen buffers | [x] |
| 86 | Major | `lib/utils/book_title.dart:83` | `displayTitle` runs 7 regexes per call, no cache | [x] |
| 87 | Minor | `lib/services/library_service.dart:502` | `notifyListeners()` per book during metadata extraction | [x] |
| 88 | Minor | `lib/screens/library_screen.dart:162-227` | `_visibleBooks` intermediate `.toList()` per filter step | [x] |

---

## EPUB Opening Performance (Round 11)

| # | Severity | File | Issue | Status |
|---|----------|------|-------|--------|
| 89 | Blocker | `lib/services/document_parser.dart:614-630` | CSS parser builds duplicate DOM per chapter (html_parser.parse called twice) | [x] |
| 90 | Major | `lib/services/document_parser.dart:631-634` | `archiveEntries` map rebuilt per spine doc (100+ copies of 200-entry map) | [x] |
| 91 | Major | `lib/screens/reader_screen.dart:213` | `loadEmbeddedFonts` awaited sequentially before first render | [x] |
| 92 | Major | `lib/services/document_parser.dart:110` | No in-memory cache — re-parses entire EPUB on re-open | [x] |

---

## Memory: Lightweight EPUB Metadata Extraction

### Problem

During library scan of 500+ books, `DocumentParser.parse()` performs a **full EPUB parse** for every book — HTML parsing, CSS compilation, chapter splitting, image resolution, font extraction, style run building — all just to extract title/author/cover. This causes massive memory spikes:

- A 10MB EPUB peaks at ~40MB (compressed bytes + decompressed archive + parsed ParsedDocument)
- `_serializeParsedDocument` triple-sizes image bytes as JSON integers for disk cache
- 500 sequential parses create extreme GC pressure

ReadEra and other efficient readers use a two-phase approach: lightweight metadata extraction (OPF + cover only), then full content parsing on-demand when the user opens the book.

### Implementation

#### Agent A — Lightweight EPUB metadata parser

| # | File | Effort | Description |
|---|------|--------|-------------|
| 89 | `lib/services/document_parser.dart` | medium | Create `_parseEpubMetadata(path)` that only reads OPF XML + cover image |
| 90 | `lib/services/document_parser.dart:110-112` | trivial | Route metadata worker to `_parseEpubMetadata` instead of full `parse()` |
| 91 | `lib/services/library_service.dart:413-527` | small | Update `_processMetadataQueue` to use metadata-only parse for EPUB |

#### Agent B — Memory cleanup after extraction

| # | File | Effort | Description |
|---|------|--------|-------------|
| 92 | `lib/screens/reader_screen.dart:57,239-266` | trivial | Null `_doc` in `dispose()` to free parsed data immediately |
| 93 | `lib/services/document_parser.dart:167,225-235` | small | Skip disk cache serialization during metadata-only parse |

### Merge point

After both agents finish, run:
```bash
flutter analyze
flutter test
```

---

### Issue #89: `_parseEpubMetadata` — Lightweight OPF + Cover Extraction

**File:** `lib/services/document_parser.dart`

**What:** Create a new function that extracts only metadata and cover from an EPUB without parsing any HTML content.

**Implementation:**
1. Open the EPUB as a ZIP archive (same as current `_parseEpub`)
2. Read `META-INF/container.xml` to find the OPF file path
3. Parse the OPF XML to extract Dublin Core metadata:
   - `dc:title` → title
   - `dc:creator` → author
   - `dc:description` → description
   - `dc:publisher` → publisher
   - `dc:language` → language
   - `dc:identifier` (ISBN) → isbn
   - `dc:date` → publicationDate
   - `dc:rights` → rights
   - `<meta name="genre">` or `<subject>` → genre
   - `<meta name="calibre:series">` or series refiner → seriesName
   - `<meta name="calibre:series_index">` → seriesIndex
   - `<meta name="cover" content="cover-image"/>` → cover image ID
4. From the manifest, find the cover image item by ID
5. Extract **only** the cover image bytes from the ZIP (single file, not entire archive)
6. Return a lightweight result (metadata fields + cover bytes)

**What it skips:** HTML parsing, CSS compilation, chapter splitting, inline image extraction, font extraction, style run building, disk cache serialization.

**Signature:**
```dart
/// Lightweight EPUB metadata + cover extraction.
/// Returns (metadata map, cover bytes) without parsing chapter content.
static Future<({Map<String, String> metadata, List<int>? coverBytes})>
    _parseEpubMetadata(String path) async { ... }
```

**OPF Parsing:** Use `xml` package (already a dependency via `csslib`) or simple regex extraction for Dublin Core fields. The OPF is a small XML file (typically <10KB).

**Cover Detection:**
1. Look for `<meta name="cover" content="cover-image"/>` in OPF metadata
2. Find the manifest item with that ID
3. Extract the file at that href from the ZIP

**Memory impact:** Per-book peak drops from ~40MB to ~2-5MB (ZIP handle + OPF XML + single cover image).

### Issue #90: Route metadata worker to lightweight parser

**File:** `lib/services/document_parser.dart:110-112`

**What:** The `parse()` function currently routes to `_parseIsolate` which does a full parse. For the metadata worker, we need a separate entry point.

**Implementation:** Add a `parseMetadata()` static method that calls `_parseEpubMetadata` for EPUB, returns minimal data for other formats (same as current behavior for PDF/TXT/CBZ).

```dart
/// Lightweight metadata extraction for library scan.
/// For EPUB: reads OPF + cover only. For others: same as parse().
static Future<ParsedDocument> parseMetadata(String path, BookFormat format) {
  return compute(_parseMetadataIsolate, (path, format));
}
```

### Issue #91: Update metadata worker

**File:** `lib/services/library_service.dart:413-527`

**What:** Change `_processMetadataQueue` to call `DocumentParser.parseMetadata()` instead of `DocumentParser.parse()`.

**Before:**
```dart
doc = await DocumentParser.parse(book.path, format);
```

**After:**
```dart
doc = await DocumentParser.parseMetadata(book.path, format);
```

The returned `ParsedDocument` will have metadata fields populated but empty chapters (for EPUB). The metadata worker already only reads metadata fields and cover bytes, so this is a drop-in replacement.

### Issue #92: Null `_doc` in reader dispose

**File:** `lib/screens/reader_screen.dart:57,239-266`

**What:** `_doc` holds the full `ParsedDocument` (all chapter text, images, fonts) but is never nullified in `dispose()`. This keeps the parsed data alive until the State object is GC'd.

**Fix:** Add `_doc = null;` in `dispose()`.

### Issue #93: Skip disk cache during metadata-only parse

**File:** `lib/services/document_parser.dart:163-169`

**What:** `_parseEpub` serializes the full `ParsedDocument` to disk cache (triple-sizing image bytes as JSON). During metadata-only extraction, this serialization is unnecessary and wasteful.

**Fix:** The metadata-only path (`_parseEpubMetadata`) doesn't produce a `ParsedDocument` with chapters, so no cache is written. The existing disk cache in `_parseEpub` is only used when the full parser is called (reader screen), which is correct.

---

## Review Round 10 — On-Call Engineer Findings

New issues found from full codebase review. These are **in addition to** the uncommitted work (lazy pagination, disk caching, font loading) already in the tree.

- [x] **94. Database migration can brick app on force-stop**
  - **File:** `lib/db/database.dart:131-162`, `onUpgrade` handler
  - **Severity:** Blocker
  - **What:** SQLite auto-commits DDL (`CREATE TABLE`, `ALTER TABLE`) outside explicit transactions. If the app is SIGKILL'd mid-migration, the schema is left partially migrated. On restart, Drift re-runs the same migration step, and already-created tables/columns cause `addColumn` to throw. **App becomes uninstallable without clearing data.**
  - **Fix:** Wrap each migration step in try-catch so partially-completed steps don't block subsequent ones.

- [x] **95. `importLibrary` phantom books**
  - **File:** `lib/services/library_service.dart:288-311`
  - **Severity:** Major
  - **What:** `_books.add(book)` at line 293 runs before bookmark/session DB inserts. If an insert throws, the catch skips the entry but the book is never removed from `_books`. The book stays in memory as a phantom (no DB rows, appears in UI).
  - **Fix:** Add rollback in catch: `_books.removeWhere((b) => b.id == book.id); _invalidateSortCache();`

- [x] **96. Metadata worker runs after dispose**
  - **File:** `lib/services/library_service.dart:80-85` and `413-531`
  - **Severity:** Major
  - **What:** `_processMetadataQueue` has no cancellation check. After `dispose()`, the while loop processes every queued item against a closed stream and null DB. Wastes CPU spawning isolates with no consumer.
  - **Fix:** Add `bool _disposed = false;` field, set `true` in `dispose()`, check in while loop.

- [x] **97. `_doc` never nullified in `ReaderScreen.dispose()`**
  - **File:** `lib/screens/reader_screen.dart:239-266`
  - **Severity:** Major
  - **What:** `_doc` (full `ParsedDocument`) is never set to null. State object retains reference after disposal, delaying GC of megabytes of parsed data.
  - **Fix:** Add `_doc = null;` in `dispose()`.

- [x] **98. `firstWhere` without `orElse` in comic provider**
  - **File:** `lib/services/comic_page_provider.dart:83`
  - **Severity:** Minor
  - **What:** `firstWhere` throws `StateError` if archive entry name doesn't match (case sensitivity). Blank page or crash for valid CBZ.
  - **Fix:** Use `firstWhereOrNull` or add `orElse` returning a clear error.

- [x] **99. `importFileFast` notifies before DB result known** — already correct; try-catch rollback handles failure
  - **File:** `lib/services/library_service.dart:384-393`
  - **Severity:** Minor
  - **What:** `notifyListeners()` fires before DB insert completes. If insert throws, UI briefly shows phantom book then it disappears.
  - **Fix:** Move `notifyListeners()` to after the try-catch block.

- [x] **100. `parse()` ignores `format` parameter**
  - **File:** `lib/services/document_parser.dart:110-112`
  - **Severity:** Nit
  - **What:** `parse()` accepts `BookFormat format` but `_parseIsolate` re-derives format from file extension. Parameter is unused and misleading.
  - **Fix:** Forward `format` to the isolate or remove the parameter.

---

## Review Round 11 — Deep Code Review Findings

Issues found from full codebase review across all layers (services, controllers, widgets, screens).

- [x] **101. `importLibrary` session dedup — sessions restored without duplicate check**
  - **File:** `lib/services/library_service.dart:303-305`
  - **Severity:** Major
  - **What:** Bookmarks get `bookmarkExists` checks (line 299), but sessions are inserted unconditionally. Importing the same backup twice duplicates all reading sessions, inflating stats.
  - **Fix:** Add dedup check matching the bookmark pattern: `if (!await _db!.sessionExists(m['id'] as String)) await _db!.insertSession(...)`.

- [x] **102. `deleteBookWithFile` — book removed from memory before DB commit**
  - **File:** `lib/services/library_service.dart:565-597`
  - **Severity:** Major
  - **What:** `_books.remove(book)` at line 568 runs before the DB transaction at lines 587-595. If the DB transaction fails (disk full, corruption), the book vanishes from the UI but persists in SQLite. On next `load()`, it reappears.
  - **Fix:** Move `_books.remove(book)` and `_invalidateSortCache()` to after the DB transaction succeeds.

- [x] **103. `_paginateNextBatch` — `setState` without `mounted` check**
  - **File:** `lib/screens/reader_screen.dart:1527`
  - **Severity:** Major
  - **What:** `setState(() {})` at line 1527 inside the pagination while-loop has no `mounted` guard. The check at line 1483 only protects entry. If the widget is disposed mid-loop (user taps back during initial pagination), this throws in debug mode.
  - **Fix:** Add `if (!mounted) return;` before `setState` at line 1527.

- [x] **104. `ReadingSessionManager.startSession` — race on rapid lifecycle toggle**
  - **File:** `lib/controllers/reading_session.dart:37-47`
  - **Severity:** Major
  - **What:** `startSession` fires async `library.startSession()` and sets `_sessionId` in `.then`. Rapid lifecycle toggle (paused→resumed→paused→resumed) causes the first `.then` to overwrite `_sessionId` after `endSession` already saved it, orphaning the session record.
  - **Fix:** Use a generation counter: increment before each `startSession`, check it in the `.then` callback before assigning `_sessionId`.

- [x] **105. `loadEmbeddedFonts` — one corrupt font aborts all font loading**
  - **File:** `lib/services/epub_css_parser.dart:415-418`
  - **Severity:** Major
  - **What:** `Future.wait(futures, eagerError: true)` cancels remaining font futures on the first failure. A single corrupt font file among several valid ones prevents all embedded fonts from loading. The book renders with system fonts instead of the intended typeface.
  - **Fix:** Remove `eagerError: true` so all fonts load independently.

- [x] **106. `_parseTxt` — no file size limit**
  - **File:** `lib/services/document_parser.dart:811`
  - **Severity:** Minor
  - **What:** EPUB caps at 100 MB (line 155), but TXT has no size guard. A 1 GB log file imported as `.txt` fully loads into memory, decodes to Dart string (tripling memory), causing OOM on 4GB devices.
  - **Fix:** Add size check before reading: `if (length > 100 * 1024 * 1024) throw FormatException(...)`.

- [x] **107. `PdfReaderController.pdfFileExists` — synchronous `existsSync` in field initializer**
  - **File:** `lib/controllers/pdf_controller.dart:20`
  - **Severity:** Minor
  - **What:** `File(book.path).existsSync()` blocks the UI thread. On slow SD cards or cloud-backed filesystems, this freezes the widget tree for hundreds of milliseconds.
  - **Fix:** Make lazy `Future<bool>` or compute in `initState`.

- [x] **108. `_processMetadataQueue` — progress counter off-by-one**
  - **File:** `lib/services/library_service.dart:502-516`
  - **Severity:** Minor
  - **What:** `completed++` at line 516 runs after the throttle check at line 504. The last item's notification fires with `completed` one behind the actual count, causing the progress bar to show 99% then jump to done.
  - **Fix:** Move `completed++` before the throttle check.

- [x] **109. `_processMetadataQueue` — pre-filter corrupts progress total**
  - **File:** `lib/services/library_service.dart:414-420`
  - **Severity:** Minor
  - **What:** `removeWhere` at line 415 modifies `_metadataQueue` in-place before `totalToProcess` is captured at line 420. Items added to the queue between these lines (via concurrent `importFileFast`) are silently dropped from processing with no notification.
  - **Fix:** Capture `totalToProcess` before the `removeWhere`, or process the removed items separately.

- [x] **110. `_showCreateCollectionAndAddSheet` — duplicate async handlers**
  - **File:** `lib/screens/library_screen.dart:823,846`
  - **Severity:** Minor
  - **What:** Both `onSubmitted` (keyboard Enter) and `onPressed` (button tap) perform the same create+add logic but can both fire if user taps button while keyboard is up. Double-create creates a duplicate collection.
  - **Fix:** Disable `onPressed` while `onSubmitted` is in flight, or deduplicate by checking if collection name already exists.

- [x] **111. `deleteCollectionById` — two deletes without transaction**
  - **File:** `lib/db/database.dart:404-408`
  - **Severity:** Minor
  - **What:** `DELETE FROM collection_books` and `DELETE FROM collections` are separate statements. Force-kill between them leaves orphaned `collection_books` rows.
  - **Fix:** Wrap both deletes in a single `customStatement` with a transaction, or use `cascade` on the foreign key.

---

## Coordination — Review Round 11 Agent Split

### Agent A — Reader + Parser fixes

Issues: #97, #103, #105, #106, #107, #100

| # | File | Severity | Effort |
|---|------|----------|--------|
| 97 | `lib/screens/reader_screen.dart:239-266` | Major | trivial (add `_doc = null;`) |
| 100 | `lib/services/document_parser.dart:110-112` | Nit | trivial (forward or remove `format` param) |
| 103 | `lib/screens/reader_screen.dart:1527` | Major | trivial (add `if (!mounted) return;`) |
| 105 | `lib/services/epub_css_parser.dart:415-418` | Major | trivial (remove `eagerError: true`) |
| 106 | `lib/services/document_parser.dart:811` | Minor | small (add size guard) |
| 107 | `lib/controllers/pdf_controller.dart:20` | Minor | small (make async) |

### Agent B — Library + DB + Controller fixes

Issues: #94, #95, #96, #98, #99, #101, #102, #104, #108, #109, #110, #111

| # | File | Severity | Effort |
|---|------|----------|--------|
| 94 | `lib/db/database.dart:131-162` | Blocker | medium (wrap each DDL in try-catch) |
| 95 | `lib/services/library_service.dart:288-311` | Major | small (rollback in catch) |
| 96 | `lib/services/library_service.dart:80-85,413-531` | Major | small (add `_disposed` flag) |
| 98 | `lib/services/comic_page_provider.dart:83` | Minor | trivial (add `orElse`) |
| 99 | `lib/services/library_service.dart:384-393` | Minor | trivial (move `notifyListeners`) |
| 101 | `lib/services/library_service.dart:303-305` | Major | small (add session dedup) |
| 102 | `lib/services/library_service.dart:565-597` | Major | small (move `_books.remove` after DB commit) |
| 104 | `lib/controllers/reading_session.dart:37-47` | Major | small (generation counter) |
| 108 | `lib/services/library_service.dart:502-516` | Minor | trivial (move `completed++`) |
| 109 | `lib/services/library_service.dart:414-420` | Minor | trivial (capture total before removeWhere) |
| 110 | `lib/screens/library_screen.dart:823,846` | Minor | small (deduplicate handlers) |
| 111 | `lib/db/database.dart:404-408` | Minor | trivial (wrap in transaction) |

### Merge point

After both agents finish, run:
```bash
flutter analyze
flutter test
```
Review combined diff together before committing.
