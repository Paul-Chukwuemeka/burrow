import 'package:flutter/material.dart';

import '../models/book.dart';
import '../services/library_service.dart';
import '../theme/burrow_tokens.dart';
import '../utils/date_format.dart';
import '../widgets/book_cover.dart';

class EditBookScreen extends StatefulWidget {
  const EditBookScreen({
    super.key,
    required this.book,
    required this.library,
  });

  final Book book;
  final LibraryService library;

  @override
  State<EditBookScreen> createState() => _EditBookScreenState();
}

class _EditBookScreenState extends State<EditBookScreen> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _authorCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _annotationCtrl;
  late final TextEditingController _genreCtrl;
  late final TextEditingController _seriesNameCtrl;
  late final TextEditingController _seriesIndexCtrl;
  late final TextEditingController _publisherCtrl;
  late final TextEditingController _isbnCtrl;
  late final TextEditingController _languageCtrl;
  late final TextEditingController _reviewCtrl;
  late final TextEditingController _pubDateCtrl;
  late final String _rawPubDate;
  late final TextEditingController _rightsCtrl;
  late final TextEditingController _typeCtrl;
  late final TextEditingController _sourceCtrl;
  late final TextEditingController _titleSortCtrl;
  late final TextEditingController _authorSortCtrl;

  @override
  void initState() {
    super.initState();
    final b = widget.book;
    _titleCtrl = TextEditingController(text: b.title);
    _authorCtrl = TextEditingController(text: b.author);
    _descCtrl = TextEditingController(text: b.description ?? '');
    _annotationCtrl = TextEditingController(text: b.annotation ?? '');
    _genreCtrl = TextEditingController(text: b.genre ?? '');
    _seriesNameCtrl = TextEditingController(text: b.seriesName ?? '');
    _seriesIndexCtrl = TextEditingController(
      text: b.seriesIndex != null ? b.seriesIndex.toString() : '',
    );
    _publisherCtrl = TextEditingController(text: b.publisher ?? '');
    _isbnCtrl = TextEditingController(text: b.isbn ?? '');
    _languageCtrl = TextEditingController(text: b.language ?? '');
    _reviewCtrl = TextEditingController(text: b.review ?? '');
    _pubDateCtrl = TextEditingController(
      text: formatPublicationDate(b.publicationDate ?? ''),
    );
    _rawPubDate = b.publicationDate ?? '';
    _rightsCtrl = TextEditingController(text: b.rights ?? '');
    _typeCtrl = TextEditingController(text: b.type ?? '');
    _sourceCtrl = TextEditingController(text: b.source ?? '');
    _titleSortCtrl = TextEditingController(text: b.titleSort ?? '');
    _authorSortCtrl = TextEditingController(text: b.authorSort ?? '');
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _authorCtrl.dispose();
    _descCtrl.dispose();
    _annotationCtrl.dispose();
    _genreCtrl.dispose();
    _seriesNameCtrl.dispose();
    _seriesIndexCtrl.dispose();
    _publisherCtrl.dispose();
    _isbnCtrl.dispose();
    _languageCtrl.dispose();
    _reviewCtrl.dispose();
    _pubDateCtrl.dispose();
    _rightsCtrl.dispose();
    _typeCtrl.dispose();
    _sourceCtrl.dispose();
    _titleSortCtrl.dispose();
    _authorSortCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Title cannot be empty')),
      );
      return;
    }

    double? seriesIndex;
    final raw = _seriesIndexCtrl.text.trim();
    if (raw.isNotEmpty) {
      seriesIndex = double.tryParse(raw);
      if (seriesIndex == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Series number must be a number')),
        );
        return;
      }
    }

    final desc = _descCtrl.text.trim();
    final annotation = _annotationCtrl.text.trim();
    final genre = _genreCtrl.text.trim();
    final seriesName = _seriesNameCtrl.text.trim();
    final publisher = _publisherCtrl.text.trim();
    final isbn = _isbnCtrl.text.trim();
    final language = _languageCtrl.text.trim();
    final review = _reviewCtrl.text.trim();
    final pubDate = _rawPubDate;
    final rights = _rightsCtrl.text.trim();
    final type = _typeCtrl.text.trim();
    final source = _sourceCtrl.text.trim();
    final titleSort = _titleSortCtrl.text.trim();
    final authorSort = _authorSortCtrl.text.trim();

    await widget.library.updateBook(
      widget.book.id,
      title: title,
      author: _authorCtrl.text.trim(),
      description: desc.isEmpty ? null : desc,
      annotation: annotation.isEmpty ? null : annotation,
      genre: genre.isEmpty ? null : genre,
      seriesName: seriesName.isEmpty ? null : seriesName,
      seriesIndex: seriesIndex,
      publisher: publisher.isEmpty ? null : publisher,
      isbn: isbn.isEmpty ? null : isbn,
      language: language.isEmpty ? null : language,
      review: review.isEmpty ? null : review,
      publicationDate: pubDate.isEmpty ? null : pubDate,
      rights: rights.isEmpty ? null : rights,
      type: type.isEmpty ? null : type,
      source: source.isEmpty ? null : source,
      titleSort: titleSort.isEmpty ? null : titleSort,
      authorSort: authorSort.isEmpty ? null : authorSort,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Metadata saved')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit book'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Cover preview
            Center(
              child: SizedBox(
                width: 120,
                child: BookCover(
                  book: widget.book,
                  borderRadius: Burrow.shapeMd,
                ),
              ),
            ),
            const SizedBox(height: 28),

            // Title
            _Field(
              label: 'Title',
              controller: _titleCtrl,
              autofocus: true,
            ),
            const SizedBox(height: 16),

            // Author
            _Field(
              label: 'Author',
              controller: _authorCtrl,
            ),
            const SizedBox(height: 16),

            // Description
            _Field(
              label: 'Description',
              controller: _descCtrl,
              maxLines: 4,
            ),
            const SizedBox(height: 16),

            // Annotation
            _Field(
              label: 'Annotation',
              controller: _annotationCtrl,
              maxLines: 3,
            ),
            const SizedBox(height: 16),

            // Genre
            _Field(
              label: 'Genre',
              controller: _genreCtrl,
            ),
            const SizedBox(height: 16),

            // Series name + index
            Row(
              children: [
                Expanded(
                  child: _Field(
                    label: 'Series',
                    controller: _seriesNameCtrl,
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 80,
                  child: _Field(
                    label: '#',
                    controller: _seriesIndexCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Publisher
            _Field(
              label: 'Publisher',
              controller: _publisherCtrl,
            ),
            const SizedBox(height: 16),

            // ISBN
            _Field(
              label: 'ISBN',
              controller: _isbnCtrl,
            ),
            const SizedBox(height: 16),

            // Language
            _Field(
              label: 'Language',
              controller: _languageCtrl,
            ),
            const SizedBox(height: 16),

            // Publication date
            _Field(
              label: 'Publication date',
              controller: _pubDateCtrl,
            ),
            const SizedBox(height: 16),

            // Rights
            _Field(
              label: 'Rights',
              controller: _rightsCtrl,
            ),
            const SizedBox(height: 16),

            // Type
            _Field(
              label: 'Type',
              controller: _typeCtrl,
            ),
            const SizedBox(height: 16),

            // Source
            _Field(
              label: 'Source',
              controller: _sourceCtrl,
            ),
            const SizedBox(height: 16),

            // Title sort
            _Field(
              label: 'Title sort',
              controller: _titleSortCtrl,
            ),
            const SizedBox(height: 16),

            // Author sort
            _Field(
              label: 'Author sort',
              controller: _authorSortCtrl,
            ),
            const SizedBox(height: 16),

            // Review / Notes
            _Field(
              label: 'Review & notes',
              controller: _reviewCtrl,
              maxLines: 4,
            ),
            const SizedBox(height: 32),

            // Save button
            FilledButton(
              onPressed: _save,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                  borderRadius: Burrow.r(Burrow.shapeSm),
                ),
              ),
              child: const Text('Save'),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    this.maxLines = 1,
    this.autofocus = false,
    this.keyboardType,
  });

  final String label;
  final TextEditingController controller;
  final int maxLines;
  final bool autofocus;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      maxLines: maxLines,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      textCapitalization: TextCapitalization.sentences,
    );
  }
}
