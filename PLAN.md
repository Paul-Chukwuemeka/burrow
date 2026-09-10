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

- [ ] **42. PdfTextSearcher listener accumulates on search toggle**
  - **File:** `lib/controllers/search_controller.dart:102-117` and `lib/screens/reader_screen.dart:702-706`
  - **What:** `toggleSearch()` nulls `_pdfSearcher` without removing the listener added at `reader_screen.dart:705`. Each open/close cycle adds a new listener to a new `PdfTextSearcher` without cleaning up the old one. Leaks the `PdfTextSearcher` and its `PdfViewerController` reference.
  - **Fix:** Remove listener in `toggleSearch` before nulling `_pdfSearcher`, or move listener management into the controller (preferred — controller should own its own listeners).

- [ ] **43. DictionaryOverlay captures stale theme and BuildContext**
  - **File:** `lib/controllers/dictionary_overlay.dart:12-18` and `lib/screens/reader_screen.dart:910-914`
  - **What:** `DictionaryOverlay` stores `BuildContext context` and `ReaderTheme theme` at construction time via `??=`. The overlay is never recreated. On theme change (sepia → dark), the toolbar renders with old colors. Also, `Overlay.of(context)` with a captured context is fragile if the overlay outlives the State.
  - **Fix:** Pass `themeBuilder: () => _settings.colors` instead of snapshot, or reset `_dictOverlay = null` in `_onSettingsChanged()` so it's recreated on next use.

- [ ] **44. Dead controller methods — `ComicReaderController.onPageChanged` and `onVerticalScroll`**
  - **File:** `lib/controllers/comic_controller.dart:113-148`
  - **What:** Controller has `onPageChanged()` and `onVerticalScroll()` that call `library.savePosition()`, but `reader_screen.dart:1147-1156` and `1199-1217` duplicate this logic inline without calling the controller methods. Dead code. The controller's `onVerticalScroll` also uses `MediaQueryData.fromView(platformDispatcher.views.first)` which bypasses text scaling.
  - **Fix:** Remove dead methods from controller, or have `reader_screen.dart` delegate to them.

- [ ] **45. `_dictOverlay` theme not refreshed on settings change**
  - **File:** `lib/screens/reader_screen.dart:910`
  - **What:** `_dictOverlay` is created with `??=` and never recreated. When theme changes via `SettingsSheet`, the overlay still uses the old theme. Follow-on to #43.
  - **Fix:** Reset `_dictOverlay = null` in `_onSettingsChanged()` so it's recreated with the new theme on next use.

- [ ] **46. `ReaderSearchController.searchOpen` is not encapsulated**
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
