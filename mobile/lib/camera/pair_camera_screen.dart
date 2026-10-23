import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../api/api_client.dart';
import '../api/households_api.dart';
import '../config.dart';
import 'device_credentials.dart';

/// First-run setup for Camera Mode: name this camera, then scan the pairing
/// QR shown in Viewer Mode ("Add camera") to join that household. The code
/// can also be typed in by hand, for devices whose camera can't focus on a
/// screen.
class PairCameraScreen extends StatefulWidget {
  const PairCameraScreen({super.key, required this.onPaired, required this.onSwitchMode, this.notice});

  final ValueChanged<DeviceCredentials> onPaired;

  /// Back to the mode picker, for someone who chose Camera Mode by mistake.
  final VoidCallback onSwitchMode;

  /// Shown above the form, e.g. explaining that this camera was removed
  /// from its household and needs pairing again.
  final String? notice;

  @override
  State<PairCameraScreen> createState() => _PairCameraScreenState();
}

class _PairCameraScreenState extends State<PairCameraScreen> {
  final _nameController = TextEditingController();
  final _codeController = TextEditingController();
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _pairing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController.addListener(() => setState(() {}));
    _codeController.addListener(() => setState(() {}));
  }

  String? get _code => PairingCode.parse(_codeController.text);

  bool get _canPair => !_pairing && _nameController.text.trim().isNotEmpty && _code != null;

  void _onDetect(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || !raw.startsWith(PairingCode.qrPrefix)) continue;
      final code = PairingCode.parse(raw);
      if (code == null || code == _code) continue;
      _codeController.text = code;
      if (_canPair) _pair();
      return;
    }
  }

  Future<void> _pair() async {
    final code = _code;
    if (code == null) return;
    setState(() {
      _pairing = true;
      _error = null;
    });
    try {
      final credentials = await DeviceCredentials.pair(
        AppConfig.serverUrl,
        code: code,
        name: _nameController.text.trim(),
      );
      await _scanner.stop();
      widget.onPaired(credentials);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _pairing = false;
        _error = e.statusCode == 400
            ? 'That code is invalid, expired, or already used. Generate a new one in Viewer Mode.'
            : 'Pairing failed (${e.statusCode}).';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pairing = false;
        _error = 'Could not reach the server: $e';
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    _scanner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scanner = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 1,
        child: MobileScanner(controller: _scanner, onDetect: _onDetect),
      ),
    );
    final notice = [
      if (widget.notice != null) ...[
        Card(
          color: theme.colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(widget.notice!, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
          ),
        ),
        const SizedBox(height: 12),
      ],
    ];
    final nameField = TextField(
      controller: _nameController,
      textCapitalization: TextCapitalization.words,
      decoration: const InputDecoration(
        labelText: 'Camera name',
        hintText: 'e.g. Front Door',
        border: OutlineInputBorder(),
      ),
    );
    final instructions = Text(
      'On your phone, open Viewer Mode → Add camera, then point this camera at the QR code.',
      style: theme.textTheme.bodyMedium,
    );
    final codeAndPair = [
      TextField(
        controller: _codeController,
        textCapitalization: TextCapitalization.characters,
        decoration: const InputDecoration(labelText: 'Or enter the pairing code', border: OutlineInputBorder()),
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _canPair ? _pair : null,
        child: _pairing
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Pair camera'),
      ),
    ];

    final appBar = AppBar(
      title: const Text('Set up this camera'),
      actions: [
        TextButton.icon(
          onPressed: widget.onSwitchMode,
          icon: const Icon(Icons.swap_horiz),
          label: const Text('Switch mode'),
        ),
      ],
    );

    // The camera phone will run in landscape, so it may well be held that
    // way while pairing: the scanner takes the left side, the form the right.
    if (MediaQuery.orientationOf(context) == Orientation.landscape) {
      return Scaffold(
        appBar: appBar,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                scanner,
                const SizedBox(width: 16),
                Expanded(
                  child: ListView(
                    children: [
                      ...notice,
                      nameField,
                      const SizedBox(height: 16),
                      instructions,
                      const SizedBox(height: 16),
                      ...codeAndPair,
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: appBar,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ...notice,
          nameField,
          const SizedBox(height: 16),
          instructions,
          const SizedBox(height: 12),
          scanner,
          const SizedBox(height: 16),
          ...codeAndPair,
        ],
      ),
    );
  }
}
