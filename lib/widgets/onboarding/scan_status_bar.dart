import 'package:flutter/material.dart';

import '../../theme/burrow_tokens.dart';

class ScanStatusBar extends StatelessWidget {
  const ScanStatusBar({
    super.key,
    required this.completed,
    required this.total,
  });

  final int completed;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = total > 0
        ? 'Importing books… $completed / $total'
        : 'Scanning for books…';

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.3)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: scheme.primary,
                  value: total > 0 ? completed / total : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          if (total > 0) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(Burrow.shapeXs),
              child: LinearProgressIndicator(
                value: completed / total,
                minHeight: 4,
                backgroundColor: scheme.primaryContainer,
                color: scheme.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
