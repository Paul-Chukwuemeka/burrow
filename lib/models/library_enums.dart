enum LibraryTab { books, authors, collections }

enum SortMode { recent, added, title }

enum LayoutMode { grid, list }

/// Where a book sits outside the active library.
///
/// `archive` is the normal, menu-visible archive; `hidden` is the PIN-gated
/// tier. Both keep the file, cover, progress, bookmarks and collection links.
enum ArchiveTier { none, archive, hidden }
