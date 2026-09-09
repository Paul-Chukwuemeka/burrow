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

- [ ] **3. N+1 and full-table-scan stat queries**
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

- [ ] **12. `Random.secure()` for ID generation**
  - **File:** `lib/services/library_service.dart:636-637`
  - **What:** `Random.secure()` is overkill for local-only IDs. `Random()` is faster.
  - **Fix:** Cosmetic. No action needed.

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
