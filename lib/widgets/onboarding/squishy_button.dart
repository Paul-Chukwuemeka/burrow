import 'package:flutter/material.dart';

import '../../theme/burrow_tokens.dart';

enum CtaVariant { filled, outlined, text, disabled }

/// Press feedback for the primary CTA: the squircle squashes wider and
/// flatter under the finger, then springs back — like a pillow being sat on.
class Squishy extends StatefulWidget {
  const Squishy({super.key, required this.onTap, required this.child});

  final VoidCallback? onTap;
  final Widget child;

  @override
  State<Squishy> createState() => SquishyState();
}

class SquishyState extends State<Squishy>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _press.forward(),
      onPointerUp: (_) => _press.reverse(),
      onPointerCancel: (_) => _press.reverse(),
      child: AnimatedBuilder(
        animation: _press,
        builder: (context, child) {
          final t = Curves.easeOutBack.transform(_press.value);
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(0, 0, 1 + 0.045 * t)
              ..setEntry(1, 1, 1 - 0.09 * t),
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}

Widget buildCta(
  BuildContext context,
  String label,
  VoidCallback? onTap, {
  CtaVariant variant = CtaVariant.filled,
}) {
  final scheme = Theme.of(context).colorScheme;
  const minSize = Size(260, 56);

  final style = switch (variant) {
    CtaVariant.filled => FilledButton.styleFrom(
        minimumSize: minSize,
        shape: RoundedSuperellipseBorder(borderRadius: Burrow.r(Burrow.shapeLg)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    CtaVariant.outlined => OutlinedButton.styleFrom(
        minimumSize: const Size(260, 50),
        shape: RoundedSuperellipseBorder(borderRadius: Burrow.r(Burrow.shapeLg)),
        foregroundColor: scheme.onSurfaceVariant,
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    CtaVariant.text => TextButton.styleFrom(
        minimumSize: const Size(260, 44),
        foregroundColor: scheme.onSurfaceVariant,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    CtaVariant.disabled => FilledButton.styleFrom(
        minimumSize: minSize,
        shape: RoundedSuperellipseBorder(borderRadius: Burrow.r(Burrow.shapeLg)),
        disabledBackgroundColor: scheme.surfaceContainerHighest,
        disabledForegroundColor: scheme.onSurfaceVariant,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
  };

  final button = switch (variant) {
    CtaVariant.filled => FilledButton(
        onPressed: onTap,
        style: style,
        child: Text(label),
      ),
    CtaVariant.outlined => OutlinedButton(
        onPressed: onTap,
        style: style,
        child: Text(label),
      ),
    CtaVariant.text => TextButton(
        onPressed: onTap,
        style: style,
        child: Text(label),
      ),
    CtaVariant.disabled => FilledButton(
        onPressed: null,
        style: style,
        child: Text(label),
      ),
  };

  if (variant == CtaVariant.filled || variant == CtaVariant.disabled) {
    return Squishy(onTap: onTap, child: button);
  }
  return button;
}
