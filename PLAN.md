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

- [ ] **13. `_showGoToPageDialog` uses wrong page count for lazy CBZ**
  - **File:** `lib/screens/reader_screen.dart:2104`
  - **What:** `final maxPage = _isPdf ? _pdfPageCount : (_isComic ? _comicPages.length : _flatPageCount);` — uses `_comicPages.length` (always 1 for lazy CBZ) instead of `_comicPageCount`. The "Go to page" dialog shows "1–1" for multi-page CBZ files.
  - **Fix:** Replace `_comicPages.length` with `_comicPageCount`:
    ```dart
    final maxPage = _isPdf ? _pdfPageCount : (_isComic ? _comicPageCount : _flatPageCount);
    ```
  - **Verify:** Open a multi-page CBZ, tap page label to open Go To Page, confirm page range is correct.

- [ ] **14. `getTotalReadingTimeMs` / `getTotalPagesRead` load full session table into Dart**
  - **File:** `lib/db/database.dart:249-267`
  - **What:** Both methods call `getSessionsForBook()` which loads ALL sessions for a book into Dart memory, then iterates to sum. For a book with 1000 sessions, this is wasteful. Called from stats screen and potentially on every page save.
  - **Fix:** Replace with SQL aggregation:
    ```dart
    Future<int> getTotalReadingTimeMs(String bookId) async {
      final result = await customSelect(
        'SELECT SUM(endedAt - startedAt) AS total FROM reading_sessions WHERE bookId = ? AND endedAt > 0',
        variables: [Variable.withInt(/* bookId */)],
      ).get();
      return result.isNotEmpty ? result.first.read<int>('total') : 0;
    }
    ```
  - **Verify:** Seed a book with 500+ sessions, measure stats screen load before/after.

- [ ] **15. `_processMetadataQueue` silently swallows all extraction errors**
  - **File:** `lib/services/library_service.dart:409-461`
  - **What:** Inner `catch (_) { completed++; continue; }` (line 418) and outer `catch (_) {}` (line 457) discard all metadata extraction errors with no logging. If every book fails to parse, the user sees "Completed" with no indication nothing was extracted.
  - **Fix:** At minimum `debugPrint` the error. Consider adding a failure count to `MetadataStatus.completed`:
    ```dart
    } catch (e) {
      debugPrint('Metadata extraction failed for ${book.title}: $e');
      completed++;
      continue;
    }
    ```

- [ ] **16. `ReaderScreenState` is 2758 lines with ~40 state variables and ~80 methods**
  - **File:** `lib/screens/reader_screen.dart:52-2411`
  - **What:** Single state class manages reflowable pagination, PDF viewing, comic viewing, search, bookmarks, sessions, dictionary overlay, settings, chrome visibility, and word selection. Any change risks regressions in unrelated features.
  - **Fix:** Extract into sub-controllers: `PdfReaderController`, `ComicReaderController`, `ReflowableReaderController`, `SearchController`. Each owns its state and disposal. The main state becomes a thin coordinator.
  - **Note:** This is a large refactor. Defer to a dedicated PR.

### Minor Issues (Review Round 2)

- [ ] **17. `_restoreComicPosition` scroll offset incorrect for vertical comics**
  - **File:** `lib/screens/reader_screen.dart:1526-1528`
  - **What:** `_comicVerticalScrollController!.jumpTo(_comicPage * viewportHeight);` assumes each comic page exactly fills the viewport height. For tall pages in `fitWidth` mode, the image may be shorter than the viewport, making the restored position land mid-page.
  - **Fix:** Track actual rendered page heights or save/restore the raw scroll offset. Judgment call — acceptable for `contain` mode.

- [ ] **18. `_restoreComicPosition` called before `_comicVerticalScrollController` is attached**
  - **File:** `lib/screens/reader_screen.dart:1520-1531`
  - **What:** `_restoreComicPosition` is called from `_loadComicPages` after `setState`, but the scroll controller is lazily created in `_buildComicVertical`. If the first build is paginated mode, the controller is null and the restore silently does nothing. Switching to vertical mode later loses the position.
  - **Fix:** Initialize the controller in `_loadComicPages` when `comicReadingMode == vertical`, or store the target offset and apply it in `_buildComicVertical`.

- [ ] **19. `deleteBook` and `deleteBookWithFile` are near-identical**
  - **File:** `lib/services/library_service.dart:506-543`
  - **What:** `deleteBook` is a strict subset of `deleteBookWithFile` with `deleteFile: false`. Two methods to maintain for the same deletion logic.
  - **Fix:** Remove `deleteBook` and have callers use `deleteBookWithFile(id)` (default `deleteFile: false`).

- [ ] **20. `_generatePdfCoverInBackground` swallows errors without logging**
  - **File:** `lib/services/library_service.dart:501`
  - **What:** `catch (_) {}` with only a comment "Thumbnail failure is non-fatal; placeholder stays." No logging at all.
  - **Fix:** `debugPrint('PDF cover generation failed: $e');`

- [ ] **21. `importLibrary` collection restore silently drops errors**
  - **File:** `lib/services/library_service.dart:305, 318`
  - **What:** Both the collection import loop and the collection-book link loop use `catch (_) {}`. A single malformed collection entry is silently lost.
  - **Fix:** `debugPrint('Failed to restore collection: $e');`

- [ ] **22. No size limit on backup file import**
  - **File:** `lib/services/library_service.dart:238`
  - **What:** `importLibrary` reads the entire backup file into memory with `File(path).readAsString()`. A maliciously crafted multi-GB JSON file could cause OOM.
  - **Fix:** Check file size before reading, reject files > 100MB.

- [ ] **23. Missing index on `Bookmarks.bookId`**
  - **File:** `lib/db/database.dart:51-61`
  - **What:** `Bookmarks.bookId` has a foreign key reference but no explicit index. Queries like `getBookmarksForBook` filter on `bookId`. With thousands of bookmarks, this is a full table scan.
  - **Fix:** Add an index: `@override List<Set<Column>> get uniqueKeys => [{id, bookId}];` or a standalone index in migration.

- [ ] **24. No tests for comic reader, PDF viewer, or scan service**
  - **File:** `test/`
  - **What:** 14 test files cover core logic well, but comic reader (`_buildComicPaginated`, `_buildComicVertical`), PDF viewer integration, and `ScanService` have no tests. High-risk areas with complex state.
  - **Fix:** Add integration tests for comic page flipping (lazy CBZ and eager CBR), PDF page navigation, and scan permission handling.

### Nit Issues (Review Round 2)

- [ ] **25. `_comicPageController` disposed via try/catch for non-comic books**
  - **File:** `lib/screens/reader_screen.dart:367-371`
  - **What:** `late final _comicPageController` throws `LateInitializationError` if accessed before initialization. The `try/catch` in `dispose` handles this, but it's a code smell.
  - **Fix:** Make `PageController? _comicPageController` nullable, initialize in `_loadComicPages`, null-check in `dispose`/`_flip`.

- [ ] **26. `_traversalPattern` regex edge case undocumented**
  - **File:** `lib/services/library_service.dart:973`
  - **What:** `RegExp(r'(?<![/\w])\.\.(?![/\w])')` — the `\w` in the lookbehind includes underscores and digits. Works correctly but the intent isn't obvious.
  - **Fix:** Add a comment: "Matches `..` not surrounded by word chars or slashes, so `/foo/../../../etc/passwd` matches but `/foo/The..Theory/book.epub` does not."

- [ ] **27. Legacy SharedPreferences key never cleared after migration**
  - **File:** `lib/services/library_service.dart:124-141`
  - **What:** After migrating to SQLite, the legacy key `burrow.library.v1` is kept as a "backup snapshot". It persists indefinitely, consuming SharedPreferences space.
  - **Fix:** Judgment call — acceptable tradeoff for data safety. No change needed.

---

## Coordination — Two-Agent Split

Two agents work in parallel on separate file groups. Each agent works through
their list top-to-bottom. Within a file group, issues are ordered to avoid
line-range conflicts (earlier issues don't shift lines that later issues depend on).

### Agent A — `reader_screen.dart` + isolated files
Issues: #1 → #4 → #5 → #10 → #9
**Status: COMPLETE** (all 5 items done)

| # | File | Lines | Effort |
|---|------|-------|--------|
| 1 | `android/app/build.gradle.kts` | 1 | trivial |
| 4 | `lib/screens/reader_screen.dart` | 2006-2017 | small |
| 5 | `lib/screens/reader_screen.dart` | 1337 | small |
| 10 | `lib/screens/reader_screen.dart` | 1719-1721 | small |
| 9 | `lib/services/comic_page_provider.dart` | 32 | trivial |

### Agent B — `library_service.dart` + `database.dart`
Issues: #6 → #7 → #8 → #2 → #12 → #3 → #11
**Status: PARTIAL** (#6, #7, #8, #2 done in previous session; #3, #12, #11 remaining)

| # | File | Lines | Effort |
|---|------|-------|--------|
| 6 | `lib/services/library_service.dart` | 155-159 | trivial |
| 7 | `lib/services/library_service.dart` | 137-139 | trivial |
| 8 | `lib/services/library_service.dart` | 260 | small |
| 2 | `lib/services/library_service.dart` | 256-278 | medium |
| 12 | `lib/services/library_service.dart` | 636-637 | trivial |
| 3 | `lib/db/database.dart` | 258-384 | large |
| 11 | `lib/db/database.dart` | 500-558 | skip (acceptable) |

### Merge point

After both agents finish, run:
```bash
flutter analyze
flutter test
```
Review combined diff together before committing.

### Work Order Suggested (sequential fallback)

1. Fix #1 (applicationId) — trivial, do first
2. Fix #4 (comic flip bug) — user-facing bug, small fix
3. Fix #6 + #7 (silent error logging) — quick wins, reduces on-call blind spots
4. Fix #5 (sync file I/O) — small fix, prevents jank
5. Fix #2 (import performance) — medium effort, high impact for heavy users
6. Fix #3 (stat queries) — largest effort, but deferred since stats are non-critical path
7. Fix #8 (path check) — judgment call, discuss with team
8. Fix #9, #10, #11, #12 — low priority, do if time permits
