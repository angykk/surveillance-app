import 'package:flutter/material.dart';

/// Asks for a new camera name, starting from [current]. Returns it trimmed,
/// or null if cancelled, left empty or unchanged.
Future<String?> showRenameCameraDialog(BuildContext context, {required String current}) async {
  final name = await showDialog<String>(
    context: context,
    builder: (context) => _RenameCameraDialog(current: current),
  );
  final trimmed = name?.trim() ?? '';
  return trimmed.isEmpty || trimmed == current ? null : trimmed;
}

/// Stateful so the text field's controller is disposed with the dialog,
/// after its closing animation, rather than leaked (or disposed while that
/// animation still shows the field).
class _RenameCameraDialog extends StatefulWidget {
  const _RenameCameraDialog({required this.current});

  final String current;

  @override
  State<_RenameCameraDialog> createState() => _RenameCameraDialogState();
}

class _RenameCameraDialogState extends State<_RenameCameraDialog> {
  late final _controller = TextEditingController(text: widget.current);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Camera name'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'e.g. Front Door'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_controller.text), child: const Text('Save')),
      ],
    );
  }
}
