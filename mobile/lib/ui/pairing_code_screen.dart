import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../api/households_api.dart';

/// "Add camera": shows a short-lived pairing code as a QR for the new
/// camera phone to scan in Camera Mode. The camera shows up in the camera
/// list on its own once it pairs, via the server's live roster.
class PairingCodeScreen extends StatefulWidget {
  const PairingCodeScreen({super.key, required this.api, required this.household});

  final HouseholdsApi api;
  final Household household;

  @override
  State<PairingCodeScreen> createState() => _PairingCodeScreenState();
}

class _PairingCodeScreenState extends State<PairingCodeScreen> {
  PairingCode? _code;
  String? _error;
  Timer? _ticker;
  Duration _remaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  Future<void> _generate() async {
    setState(() {
      _code = null;
      _error = null;
    });
    try {
      final code = await widget.api.createPairingCode(widget.household.id);
      if (!mounted) return;
      setState(() => _code = code);
      _ticker?.cancel();
      _tick();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not create a pairing code: $e');
    }
  }

  void _tick() {
    final code = _code;
    if (code == null || !mounted) return;
    final remaining = code.expiresAt.difference(DateTime.now());
    setState(() => _remaining = remaining.isNegative ? Duration.zero : remaining);
    if (remaining.isNegative) _ticker?.cancel();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = _code;
    final expired = code != null && _remaining == Duration.zero;
    final minutes = _remaining.inMinutes;
    final seconds = (_remaining.inSeconds % 60).toString().padLeft(2, '0');

    return Scaffold(
      appBar: AppBar(title: Text('Add camera to ${widget.household.name}')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: _error != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    ElevatedButton(onPressed: _generate, child: const Text('Retry')),
                  ],
                )
              : code == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'On the phone you want to use as a camera, open Camera Mode and scan this code.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 24),
                        Opacity(
                          opacity: expired ? 0.2 : 1,
                          child: Container(
                            // QR scanners need dark-on-light with a quiet
                            // zone, whatever the app's theme is.
                            color: Colors.white,
                            padding: const EdgeInsets.all(16),
                            child: QrImageView(data: code.qrPayload, size: 240),
                          ),
                        ),
                        const SizedBox(height: 16),
                        SelectableText(
                          '${code.code.substring(0, 4)}-${code.code.substring(4)}',
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontFamily: 'monospace',
                            letterSpacing: 4,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          expired ? 'This code has expired.' : 'Expires in $minutes:$seconds · single use',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 24),
                        if (expired)
                          FilledButton(onPressed: _generate, child: const Text('New code'))
                        else
                          OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Done'),
                          ),
                      ],
                    ),
        ),
      ),
    );
  }
}
