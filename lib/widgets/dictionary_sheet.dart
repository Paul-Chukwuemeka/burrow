import 'package:flutter/material.dart';
import 'package:lexicor/lexicor.dart';

import '../models/reader_settings.dart';
import '../services/dictionary_service.dart';

/// Bottom sheet that displays a word's dictionary definition.
abstract final class DictionarySheet {
  static Future<void> show(
    BuildContext context, {
    required String word,
    required ReaderTheme theme,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _DictionaryContent(word: word, theme: theme),
    );
  }
}

class _DictionaryContent extends StatefulWidget {
  const _DictionaryContent({required this.word, required this.theme});

  final String word;
  final ReaderTheme theme;

  @override
  State<_DictionaryContent> createState() => _DictionaryContentState();
}

class _DictionaryContentState extends State<_DictionaryContent> {
  LookupResult? _result;
  Map<SpeechPart, List<Concept>> _grouped = {};
  List<String> _examples = [];
  List<String> _synonyms = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _lookup();
  }

  Future<void> _lookup() async {
    try {
      await DictionaryService.instance.ensureReady();

      final result = DictionaryService.instance.lookup(widget.word);
      if (!mounted) return;

      if (result == null || result.isEmpty) {
        setState(() {
          _result = null;
          _loading = false;
        });
        return;
      }

      final primary = result.primary;
      final examples = primary != null
          ? DictionaryService.instance.examples(primary)
          : <String>[];
      final synonyms = primary != null
          ? DictionaryService.instance.synonyms(primary)
          : <String>[];

      setState(() {
        _result = result;
        _grouped = result.groupByPos();
        _examples = examples;
        _synonyms = synonyms;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.theme.background;
    final text = widget.theme.text;
    final muted = widget.theme.muted;
    final accent = widget.theme.accent;

    final screenHeight = MediaQuery.sizeOf(context).height;

    return Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: screenHeight * 0.75),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: muted.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              widget.word,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: text,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_loading) ...[
                      const SizedBox(height: 24),
                      Center(child: CircularProgressIndicator(color: accent)),
                      const SizedBox(height: 16),
                    ] else if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        'Failed to load definition',
                        style: TextStyle(color: muted, fontSize: 14),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Please check your connection and try again.',
                        style: TextStyle(color: muted, fontSize: 12),
                      ),
                    ] else if (_result == null || _result!.isEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        'No definition found',
                        style: TextStyle(color: muted, fontSize: 14),
                      ),
                      if (_result != null &&
                          _result!.resolvedForms.length > 1) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Searched as: ${_result!.resolvedForms.join(", ")}',
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                      ],
                    ] else ...[
                      const SizedBox(height: 16),
                      for (final entry in _grouped.entries) ...[
                        _PosHeader(label: entry.key.label, color: accent),
                        const SizedBox(height: 8),
                        for (int i = 0; i < entry.value.length; i++) ...[
                          if (i > 0) const SizedBox(height: 8),
                          _DefinitionTile(
                            index: i + 1,
                            definition: entry.value[i].definition,
                            category: entry.value[i].category.label,
                            muted: muted,
                            text: text,
                          ),
                        ],
                        const SizedBox(height: 12),
                      ],

                      if (_examples.isNotEmpty) ...[
                        Text(
                          'Examples',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: accent,
                          ),
                        ),
                        const SizedBox(height: 6),
                        for (final example in _examples.take(3)) ...[
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              '"$example"',
                              style: TextStyle(
                                fontSize: 13,
                                fontStyle: FontStyle.italic,
                                color: muted,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                      ],

                      if (_synonyms.isNotEmpty) ...[
                        Text(
                          'Synonyms',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: accent,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final syn in _synonyms.take(8))
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: accent.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  syn,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: accent,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _PosHeader extends StatelessWidget {
  const _PosHeader({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IntrinsicWidth(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _DefinitionTile extends StatelessWidget {
  const _DefinitionTile({
    required this.index,
    required this.definition,
    required this.category,
    required this.muted,
    required this.text,
  });

  final int index;
  final String? definition;
  final String category;
  final Color muted;
  final Color text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$index.',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: muted,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (definition != null)
                Text(
                  definition!,
                  style: TextStyle(fontSize: 14, color: text, height: 1.4),
                )
              else
                Text(
                  '(no definition)',
                  style: TextStyle(
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                    color: muted,
                  ),
                ),
              if (category.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    category,
                    style: TextStyle(
                      fontSize: 11,
                      color: muted.withValues(alpha: 0.7),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
