import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Book metadata fetched from an online API.
class ApiBookMetadata {
  final String? title;
  final String? author;
  final String? description;
  final String? genre;
  final String? seriesName;
  final double? seriesIndex;
  final String? publisher;
  final String? isbn;
  final String? language;
  final String? publicationDate;
  final String? coverUrl;

  const ApiBookMetadata({
    this.title,
    this.author,
    this.description,
    this.genre,
    this.seriesName,
    this.seriesIndex,
    this.publisher,
    this.isbn,
    this.language,
    this.publicationDate,
    this.coverUrl,
  });

  /// Returns a copy with only non-null fields from [other] filling in nulls.
  ApiBookMetadata merge(ApiBookMetadata other) => ApiBookMetadata(
    title: title ?? other.title,
    author: author ?? other.author,
    description: description != null && description!.length >= (other.description?.length ?? 0)
        ? description
        : other.description ?? description,
    genre: _mergeGenres(genre, other.genre),
    seriesName: seriesName ?? other.seriesName,
    seriesIndex: seriesIndex ?? other.seriesIndex,
    publisher: publisher ?? other.publisher,
    isbn: isbn ?? other.isbn,
    language: language ?? other.language,
    publicationDate: publicationDate ?? other.publicationDate,
    coverUrl: coverUrl ?? other.coverUrl,
  );

  static String? _mergeGenres(String? a, String? b) {
    if (a == null || a.isEmpty) return b;
    if (b == null || b.isEmpty) return a;
    final set = {
      for (final g in a.split(',')) g.trim().toLowerCase(),
    };
    final merged = <String>[...a.split(',').map((s) => s.trim())];
    for (final g in b.split(',')) {
      final trimmed = g.trim();
      if (trimmed.isNotEmpty && !set.contains(trimmed.toLowerCase())) {
        merged.add(trimmed);
      }
    }
    return merged.join(', ');
  }
}

/// Fetches book metadata from Google Books and Open Library APIs.
class MetadataApiService {
  MetadataApiService._();

  static const _googleBooksBase = 'https://www.googleapis.com/books/v1/volumes';
  static const _openLibraryBase = 'https://openlibrary.org';
  static const _timeout = Duration(seconds: 10);
  static const _coverTimeout = Duration(seconds: 15);

  // ---------------------------------------------------------------------------
  // Public
  // ---------------------------------------------------------------------------

  /// Fetches metadata from Google Books (primary) and Open Library (fallback).
  static Future<ApiBookMetadata?> fetchMetadata({
    String? isbn,
    String? title,
    String? author,
  }) async {
    ApiBookMetadata? result;

    try {
      result = await fetchFromGoogleBooks(isbn: isbn, title: title, author: author);
    } catch (e) {
      debugPrint('MetadataApiService: Google Books fetch failed: $e');
    }

    // Try Open Library for anything Google Books didn't return.
    try {
      final ol = await fetchFromOpenLibrary(isbn: isbn, title: title, author: author);
      if (ol != null) {
        result = result?.merge(ol) ?? ol;
      }
    } catch (e) {
      debugPrint('MetadataApiService: Open Library fetch failed: $e');
    }

    return result;
  }

  /// Downloads cover image bytes from [url].
  static Future<List<int>?> downloadCover(String url) async {
    final uri = Uri.parse(url);
    if (uri.scheme != 'https') return null;
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri).timeout(_coverTimeout);
      final response = await request.close().timeout(_coverTimeout);
      if (response.statusCode != 200) return null;
      // Cap at ~10 MB to prevent downloading a multi-GB payload.
      const maxBytes = 10 * 1024 * 1024;
      var total = 0;
      final chunks = <List<int>>[];
      await for (final chunk in response) {
        total += chunk.length;
        if (total > maxBytes) {
          debugPrint('MetadataApiService: cover too large, aborting download');
          return null;
        }
        chunks.add(chunk);
      }
      return chunks.expand((c) => c).toList();
    } catch (e) {
      debugPrint('MetadataApiService: cover download failed: $e');
      return null;
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Search (multiple results)
  // ---------------------------------------------------------------------------

  /// Searches both Google Books and Open Library, returns merged results.
  static Future<List<ApiBookMetadata>> search({
    required String query,
    int maxResults = 10,
  }) async {
    final results = <ApiBookMetadata>[];

    try {
      final gb = await _searchGoogleBooks(query: query, maxResults: maxResults);
      results.addAll(gb);
    } catch (e) {
      debugPrint('MetadataApiService: Google Books search failed: $e');
    }

    try {
      final ol = await _searchOpenLibraryAll(query: query, limit: maxResults);
      // Deduplicate by title+author.
      for (final item in ol) {
        final isDupe = results.any((r) =>
            r.title?.toLowerCase() == item.title?.toLowerCase() &&
            r.author?.toLowerCase() == item.author?.toLowerCase());
        if (!isDupe) results.add(item);
      }
    } catch (e) {
      debugPrint('MetadataApiService: Open Library search failed: $e');
    }

    return results;
  }

  // ---------------------------------------------------------------------------
  // Google Books
  // ---------------------------------------------------------------------------

  static Future<ApiBookMetadata?> fetchFromGoogleBooks({
    String? isbn,
    String? title,
    String? author,
  }) async {
    final query = _buildGoogleBooksQuery(isbn: isbn, title: title, author: author);
    if (query == null) return null;

    final results = await _searchGoogleBooks(query: query, maxResults: 1);
    return results.isEmpty ? null : results.first;
  }

  /// Reads an HTTP response body with a hard byte-cap and timeout.
  ///
  /// `.take(n)` on a stream counts *events* (chunks), not bytes, so it is
  /// useless as a size guard.  This helper counts actual bytes and aborts
  /// once [maxBytes] is exceeded.
  static Future<String> _readBodyBounded(
    HttpClientResponse response, {
    int maxBytes = 10 * 1024 * 1024,
  }) async {
    final chunks = <List<int>>[];
    var total = 0;
    final sub = response.listen(
      (chunk) {
        total += chunk.length;
        chunks.add(chunk);
      },
      onDone: () {},
      onError: (e) {},
    );
    final timer = Timer(_timeout, () {
      sub.cancel();
    });
    await sub.asFuture<void>();
    timer.cancel();
    if (total > maxBytes) {
      throw FormatException('Response body exceeds $maxBytes bytes');
    }
    return utf8.decode(chunks.expand((c) => c).toList(), allowMalformed: true);
  }

  static Future<List<ApiBookMetadata>> _searchGoogleBooks({
    required String query,
    int maxResults = 10,
  }) async {
    final uri = Uri.parse(_googleBooksBase).replace(queryParameters: {
      'q': query,
      'maxResults': maxResults.toString(),
    });

    final client = HttpClient();
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) return [];

      final body = await _readBodyBounded(response);
      final json = jsonDecode(body) as Map<String, dynamic>;
      final items = json['items'] as List?;
      if (items == null || items.isEmpty) return [];

      final parsed = <ApiBookMetadata>[];
      for (final item in items) {
        try {
          parsed.add(_parseGoogleBooksVolume(item as Map<String, dynamic>));
        } catch (_) {}
      }
      return parsed;
    } catch (e) {
      debugPrint('MetadataApiService: Google Books API error: $e');
      return [];
    } finally {
      client.close();
    }
  }

  static String? _buildGoogleBooksQuery({
    String? isbn,
    String? title,
    String? author,
  }) {
    if (isbn != null && isbn.isNotEmpty) {
      return 'isbn:$isbn';
    }
    if (title != null && title.isNotEmpty) {
      final parts = <String>['intitle:$title'];
      if (author != null && author.isNotEmpty) {
        parts.add('inauthor:$author');
      }
      return parts.join('+');
    }
    return null;
  }

  static ApiBookMetadata _parseGoogleBooksVolume(Map<String, dynamic> item) {
    final info = item['volumeInfo'] as Map<String, dynamic>? ?? {};

    final title = info['title'] as String?;
    final subtitle = info['subtitle'] as String?;
    final fullTitle = subtitle != null && subtitle.isNotEmpty ? '$title: $subtitle' : title;

    final authors = (info['authors'] as List?)?.cast<String>();
    final author = authors?.join(', ');

    final categories = (info['categories'] as List?)?.cast<String>();
    final genre = categories?.join(', ');

    final industryIds = (info['industryIdentifiers'] as List?) ?? [];
    String? foundIsbn;
    for (final id in industryIds) {
      final idMap = id as Map<String, dynamic>;
      if (idMap['type'] == 'ISBN_13') {
        foundIsbn = idMap['identifier'] as String?;
        break;
      }
      if (idMap['type'] == 'ISBN_10' && foundIsbn == null) {
        foundIsbn = idMap['identifier'] as String?;
      }
    }

    final imageLinks = info['imageLinks'] as Map<String, dynamic>?;
    var coverUrl = imageLinks?['thumbnail'] as String?;
    // Upgrade to higher resolution.
    coverUrl = coverUrl?.replaceFirst('http://', 'https://');
    coverUrl = coverUrl?.replaceFirst('edge=curl', 'edge=curl&fife=w400');

    // Series info: try volumeInfo.series first, then parse from title.
    String? seriesName;
    double? seriesIndex;
    final apiSeries = info['series'] as String?;
    if (apiSeries != null && apiSeries.isNotEmpty) {
      seriesName = apiSeries;
    }
    final parsed = _parseSeriesFromTitle(fullTitle);
    if (seriesName == null && parsed != null) {
      seriesName = parsed.name;
    }
    seriesIndex ??= parsed?.index;

    return ApiBookMetadata(
      title: fullTitle,
      author: author,
      description: info['description'] as String?,
      genre: genre,
      seriesName: seriesName,
      seriesIndex: seriesIndex,
      publisher: info['publisher'] as String?,
      isbn: foundIsbn,
      language: info['language'] as String?,
      publicationDate: info['publishedDate'] as String?,
      coverUrl: coverUrl,
    );
  }

  /// Tries to extract series name and index from a title string.
  ///
  /// Common patterns:
  ///   "Harry Potter #3"
  ///   "Harry Potter, Book 3"
  ///   "Harry Potter: The Prisoner of Azkaban (3)"
  ///   "The Lord of the Rings - Vol. 2"
  static _ParsedSeries? _parseSeriesFromTitle(String? title) {
    if (title == null || title.isEmpty) return null;

    // "#N" at end of title.
    final hashMatch = RegExp(r'#\s*(\d+(?:\.\d+)?)\s*$').firstMatch(title);
    if (hashMatch != null) {
      final name = title.substring(0, hashMatch.start).trim();
      final index = double.tryParse(hashMatch.group(1)!);
      if (name.isNotEmpty) return _ParsedSeries(name, index);
    }

    // "Book N" or "Vol N" or "Volume N" at end.
    final bookMatch = RegExp(
      r'(?:Book|Vol(?:\.|ume)?)\s*(\d+(?:\.\d+)?)\s*$',
    ).firstMatch(title);
    if (bookMatch != null) {
      final name = title.substring(0, bookMatch.start).trim();
      final index = double.tryParse(bookMatch.group(1)!);
      if (name.isNotEmpty) return _ParsedSeries(name, index);
    }

    // "(N)" at end.
    final parenMatch = RegExp(r'\((\d+(?:\.\d+)?)\)\s*$').firstMatch(title);
    if (parenMatch != null) {
      final name = title.substring(0, parenMatch.start).trim();
      final index = double.tryParse(parenMatch.group(1)!);
      if (name.isNotEmpty) return _ParsedSeries(name, index);
    }

    // "- N" or ": N" at end.
    final dashMatch = RegExp(r'[-:]\s*(\d+(?:\.\d+)?)\s*$').firstMatch(title);
    if (dashMatch != null) {
      final name = title.substring(0, dashMatch.start).trim();
      final index = double.tryParse(dashMatch.group(1)!);
      if (name.isNotEmpty) return _ParsedSeries(name, index);
    }

    return null;
  }

  // ---------------------------------------------------------------------------
  // Open Library
  // ---------------------------------------------------------------------------

  static Future<ApiBookMetadata?> fetchFromOpenLibrary({
    String? isbn,
    String? title,
    String? author,
  }) async {
    // Try ISBN first.
    if (isbn != null && isbn.isNotEmpty) {
      final result = await _fetchOpenLibraryByIsbn(isbn);
      if (result != null) return result;
    }

    // Fall back to search.
    if (title != null && title.isNotEmpty) {
      return _searchOpenLibrary(title: title, author: author);
    }

    return null;
  }

  static Future<ApiBookMetadata?> _fetchOpenLibraryByIsbn(String isbn) async {
    final uri = Uri.parse('$_openLibraryBase/isbn/$isbn.json');

    final client = HttpClient();
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) return null;

      final body = await _readBodyBounded(response);
      final json = jsonDecode(body) as Map<String, dynamic>;
      return _parseOpenLibraryBook(json, isbn: isbn);
    } catch (e) {
      debugPrint('MetadataApiService: Open Library ISBN lookup failed: $e');
      return null;
    } finally {
      client.close();
    }
  }

  static Future<ApiBookMetadata?> _searchOpenLibrary({
    required String title,
    String? author,
  }) async {
    final results = await _searchOpenLibraryAll(query: title, limit: 1);
    return results.isEmpty ? null : results.first;
  }

  static Future<List<ApiBookMetadata>> _searchOpenLibraryAll({
    required String query,
    int limit = 10,
  }) async {
    final params = <String, String>{
      'title': query,
      'limit': limit.toString(),
      'fields': 'key,title,author_name,subject,publisher,isbn,published_date,number_of_pages_median,cover_i',
    };

    final uri = Uri.parse('$_openLibraryBase/search.json').replace(queryParameters: params);

    final client = HttpClient();
    try {
      final request = await client.getUrl(uri).timeout(_timeout);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) return [];

      final body = await _readBodyBounded(response);
      final json = jsonDecode(body) as Map<String, dynamic>;
      final docs = json['docs'] as List?;
      if (docs == null || docs.isEmpty) return [];

      final parsed = <ApiBookMetadata>[];
      for (final doc in docs) {
        try {
          parsed.add(_parseOpenLibrarySearchResult(doc as Map<String, dynamic>));
        } catch (_) {}
      }
      return parsed;
    } catch (e) {
      debugPrint('MetadataApiService: Open Library search failed: $e');
      return [];
    } finally {
      client.close();
    }
  }

  static ApiBookMetadata _parseOpenLibraryBook(
    Map<String, dynamic> json, {
    String? isbn,
  }) {
    final title = json['title'] as String?;

    final authors = (json['authors'] as List?)
        ?.map((a) => (a as Map<String, dynamic>)['name'] as String?)
        .whereType<String>()
        .toList();
    final author = authors?.isNotEmpty == true ? authors!.join(', ') : null;

    final subjects = (json['subjects'] as List?)?.cast<String>();
    final genre = subjects?.take(5).join(', ');

    final publishers = (json['publishers'] as List?)?.cast<String>();
    final publisher = publishers?.isNotEmpty == true ? publishers!.first : null;

    final coverId = json['cover'] as Map<String, dynamic>?;
    final coverUrl = coverId != null ? 'https://covers.openlibrary.org/b/id/${coverId['large'] ?? coverId['medium'] ?? coverId['small']}-L.jpg' : null;

    return ApiBookMetadata(
      title: title,
      author: author,
      genre: genre,
      publisher: publisher,
      isbn: isbn,
      coverUrl: coverUrl,
    );
  }

  static ApiBookMetadata _parseOpenLibrarySearchResult(Map<String, dynamic> doc) {
    final title = doc['title'] as String?;
    final authors = (doc['author_name'] as List?)?.cast<String>();
    final author = authors?.isNotEmpty == true ? authors!.join(', ') : null;
    final subjects = (doc['subject'] as List?)?.cast<String>();
    final genre = subjects?.take(5).join(', ');
    final publishers = (doc['publisher'] as List?)?.cast<String>();
    final publisher = publishers?.isNotEmpty == true ? publishers!.first : null;
    final isbns = (doc['isbn'] as List?)?.cast<String>();
    final isbn = isbns?.firstWhere(
      (i) => i.length == 13 || i.length == 10,
      orElse: () => '',
    );
    final pubDate = doc['published_date'] as String?;
    final coverId = doc['cover_i'] as int?;
    final coverUrl = coverId != null ? 'https://covers.openlibrary.org/b/id/$coverId-L.jpg' : null;

    return ApiBookMetadata(
      title: title,
      author: author,
      genre: genre,
      publisher: publisher,
      isbn: isbn?.isNotEmpty == true ? isbn : null,
      publicationDate: pubDate,
      coverUrl: coverUrl,
    );
  }
}

class _ParsedSeries {
  final String name;
  final double? index;
  const _ParsedSeries(this.name, this.index);
}
