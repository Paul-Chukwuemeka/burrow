import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/reader_settings.dart';

class ReaderChrome extends StatefulWidget {
  const ReaderChrome({
    super.key,
    required this.visible,
    required this.theme,
    required this.settings,
    required this.book,
    required this.centerLabel,
    required this.sliderMax,
    required this.sliderValue,
    required this.sliderLabel,
    required this.onSliderChanged,
    required this.onTapLeft,
    required this.onTapRight,
    required this.onToggleSearch,
    required this.onToggleBookmark,
    required this.onShowToc,
    required this.onShowSettings,
    required this.isBookmarked,
    this.comicPreviewVisible = false,
    required this.onToggleComicPreview,
    this.comicPreviewStrip,
    this.onGoToPage,
    this.onKeyEvent,
  });

  final bool visible;
  final ReaderTheme theme;
  final ReaderSettings settings;
  final Book book;
  final String centerLabel;
  final int sliderMax;
  final int sliderValue;
  final String sliderLabel;
  final ValueChanged<int> onSliderChanged;
  final VoidCallback onTapLeft;
  final VoidCallback onTapRight;
  final VoidCallback onToggleSearch;
  final VoidCallback onToggleBookmark;
  final VoidCallback onShowToc;
  final VoidCallback onShowSettings;
  final bool isBookmarked;
  final bool comicPreviewVisible;
  final VoidCallback onToggleComicPreview;
  final Widget? comicPreviewStrip;
  final VoidCallback? onGoToPage;
  final void Function(KeyEvent)? onKeyEvent;

  @override
  State<ReaderChrome> createState() => _ReaderChromeState();
}

class _ReaderChromeState extends State<ReaderChrome> {
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  bool get _showToc =>
      widget.book.format != BookFormat.cbz &&
      widget.book.format != BookFormat.cbr;
  bool get _showSearch => _showToc;
  bool get _showBookmark => _showToc;
  bool get _isComic =>
      widget.book.format == BookFormat.cbz ||
      widget.book.format == BookFormat.cbr;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return AnimatedOpacity(
      opacity: widget.visible ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: Column(
        children: [
          Container(
            color: theme.background.withValues(alpha: 0.97),
            padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.arrow_back, color: theme.text),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: Text(
                    widget.book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: theme.text),
                  ),
                ),
                if (_showToc)
                  IconButton(
                    icon: Icon(Icons.toc, color: theme.text),
                    onPressed: widget.onShowToc,
                  ),
                if (_showSearch)
                  IconButton(
                    icon: Icon(Icons.search, color: theme.text),
                    onPressed: widget.onToggleSearch,
                  ),
                if (_showBookmark)
                  IconButton(
                    icon: Icon(
                      widget.isBookmarked
                          ? Icons.bookmark
                          : Icons.bookmark_border,
                      color: widget.isBookmarked ? theme.accent : theme.text,
                    ),
                    onPressed: widget.onToggleBookmark,
                  ),
                if (_isComic)
                  IconButton(
                    icon: Icon(
                      widget.comicPreviewVisible
                          ? Icons.view_carousel
                          : Icons.view_carousel_outlined,
                      color: widget.comicPreviewVisible
                          ? theme.accent
                          : theme.text,
                    ),
                    onPressed: widget.onToggleComicPreview,
                  ),
                IconButton(
                  icon: Icon(Icons.text_fields, color: theme.text),
                  onPressed: widget.onShowSettings,
                ),
              ],
            ),
          ),
          const Spacer(),
          Container(
            color: theme.background.withValues(alpha: 0.97),
            padding: EdgeInsets.fromLTRB(
              16,
              8,
              16,
              MediaQuery.paddingOf(context).bottom + 8,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isComic &&
                    widget.comicPreviewVisible &&
                    widget.comicPreviewStrip != null) ...[
                  widget.comicPreviewStrip!,
                  const SizedBox(height: 8),
                ],
                GestureDetector(
                  onTap: widget.onGoToPage,
                  child: Text(
                    widget.centerLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: theme.text,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.sliderLabel,
                  style: TextStyle(fontSize: 12, color: theme.muted),
                ),
                const SizedBox(height: 2),
                SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: theme.accent,
                    thumbColor: theme.accent,
                    inactiveTrackColor: theme.muted.withValues(alpha: 0.3),
                  ),
                  child: Slider(
                    value: widget.sliderValue.toDouble(),
                    max: widget.sliderMax.toDouble(),
                    onChanged: (v) => widget.onSliderChanged(v.round()),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
