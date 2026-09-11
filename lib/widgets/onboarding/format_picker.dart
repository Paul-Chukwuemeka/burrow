import 'package:flutter/material.dart';

class FormatPicker extends StatelessWidget {
  const FormatPicker({
    super.key,
    required this.selectedFormats,
    required this.onChanged,
  });

  final Set<String> selectedFormats;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final formats = [
      ('.epub', 'EPUB', Icons.menu_book_rounded, scheme.primaryContainer, scheme.onPrimaryContainer),
      ('.txt', 'TXT', Icons.description_outlined, const Color(0xFFFFE3BC), const Color(0xFF5A421A)),
      ('.pdf', 'PDF', Icons.picture_as_pdf_rounded, const Color(0xFFFFDACF), const Color(0xFF66241A)),
      ('.cbz', 'CBZ', Icons.collections_rounded, const Color(0xFFE8DEF8), const Color(0xFF4A3560)),
      ('.cbr', 'CBR', Icons.collections_rounded, const Color(0xFFD0E8E0), const Color(0xFF1A4A3A)),
    ];

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      alignment: WrapAlignment.center,
      children: formats.map((f) {
        final (ext, label, icon, bg, fg) = f;
        final selected = selectedFormats.contains(ext);
        return GestureDetector(
          onTap: () {
            final next = Set<String>.from(selectedFormats);
            if (selected) {
              next.remove(ext);
            } else {
              next.add(ext);
            }
            onChanged(next);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? bg : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(99),
              border: Border.all(
                color: selected ? fg.withValues(alpha: 0.4) : scheme.outlineVariant.withValues(alpha: 0.5),
                width: selected ? 2 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? Icons.check_circle_rounded : icon,
                  size: 18,
                  color: selected ? fg : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? fg : scheme.onSurfaceVariant,
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}

/// Decorative format chips shown on the permission page.
Widget formatChips(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  Widget chip(String label, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: fg,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
          ),
        ),
      );
  return Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      chip('EPUB', scheme.primaryContainer, scheme.onPrimaryContainer),
      const SizedBox(width: 8),
      chip('TXT', const Color(0xFFFFE3BC), const Color(0xFF5A421A)),
      const SizedBox(width: 8),
      chip('PDF', const Color(0xFFFFDACF), const Color(0xFF66241A)),
    ],
  );
}
