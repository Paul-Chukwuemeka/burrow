import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/archive_pin_service.dart';

/// Prompts for the Hidden Archive PIN, creating one on first use.
///
/// Returns true when the caller may open the hidden tier.
Future<bool> ensureHiddenArchiveUnlocked(BuildContext context) async {
  if (await ArchivePinService.hasPin()) {
    if (!context.mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (_) => const _ArchivePinUnlockDialog(),
        ) ??
        false;
  }
  if (!context.mounted) return false;
  return await showDialog<bool>(
        context: context,
        builder: (_) => const _ArchivePinSetupDialog(),
      ) ??
      false;
}

/// Settings flow: verify the current PIN, then replace it.
///
/// Returns true when a new PIN was saved.
Future<bool> changeHiddenArchivePin(BuildContext context) async {
  if (await ArchivePinService.hasPin()) {
    if (!context.mounted) return false;
    final unlocked =
        await showDialog<bool>(
          context: context,
          builder: (_) => const _ArchivePinUnlockDialog(
            title: 'Current hidden archive PIN',
          ),
        ) ??
        false;
    if (!unlocked) return false;
  }
  if (!context.mounted) return false;
  return await showDialog<bool>(
        context: context,
        builder: (_) =>
            const _ArchivePinSetupDialog(title: 'Set a new hidden archive PIN'),
      ) ??
      false;
}

class _ArchivePinSetupDialog extends StatefulWidget {
  const _ArchivePinSetupDialog({this.title = 'Create hidden archive PIN'});

  final String title;

  @override
  State<_ArchivePinSetupDialog> createState() => _ArchivePinSetupDialogState();
}

class _ArchivePinSetupDialogState extends State<_ArchivePinSetupDialog> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_pin.text.length != 4 || !RegExp(r'^\d{4}$').hasMatch(_pin.text)) {
      setState(() => _error = 'PIN must be exactly four digits');
      return;
    }
    if (_pin.text != _confirm.text) {
      setState(() => _error = 'PINs do not match');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ArchivePinService.setPin(_pin.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save PIN';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'This PIN unlocks the hidden archive. There is no recovery if you '
            'forget it.',
          ),
          const SizedBox(height: 16),
          _PinField(
            controller: _pin,
            label: '4-digit PIN',
            autofocus: true,
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          _PinField(
            controller: _confirm,
            label: 'Confirm PIN',
            onSubmitted: (_) => _save(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class _ArchivePinUnlockDialog extends StatefulWidget {
  const _ArchivePinUnlockDialog({this.title = 'Hidden archive'});

  final String title;

  @override
  State<_ArchivePinUnlockDialog> createState() =>
      _ArchivePinUnlockDialogState();
}

class _ArchivePinUnlockDialogState extends State<_ArchivePinUnlockDialog> {
  final _pin = TextEditingController();
  String? _error;
  bool _checking = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    final ok = await ArchivePinService.verifyPin(_pin.text);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _checking = false;
      _error = 'Incorrect PIN';
      _pin.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Enter your 4-digit PIN'),
          const SizedBox(height: 16),
          _PinField(
            controller: _pin,
            label: 'PIN',
            autofocus: true,
            onSubmitted: (_) => _unlock(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _checking ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _checking ? null : _unlock,
          child: const Text('Unlock'),
        ),
      ],
    );
  }
}

class _PinField extends StatelessWidget {
  const _PinField({
    required this.controller,
    required this.label,
    this.autofocus = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      obscureText: true,
      keyboardType: TextInputType.number,
      maxLength: 4,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        counterText: '',
        border: const OutlineInputBorder(),
      ),
      onSubmitted: onSubmitted,
    );
  }
}
