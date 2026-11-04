import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../api/api_client.dart';
import '../api/households_api.dart';
import 'shared_widgets.dart';

/// "Join a household": redeems an invite code (typed, or scanned from the
/// QR shown by InviteScreen) and adds this account as a member at whatever
/// role the invite was minted for.
class AcceptInviteScreen extends StatefulWidget {
  const AcceptInviteScreen({super.key, required this.api});

  final HouseholdsApi api;

  @override
  State<AcceptInviteScreen> createState() => _AcceptInviteScreenState();
}

class _AcceptInviteScreenState extends State<AcceptInviteScreen> {
  final _codeController = TextEditingController();
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _joining = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _codeController.addListener(() => setState(() {}));
  }

  String? get _code => Invite.parse(_codeController.text);

  bool get _canJoin => !_joining && _code != null;

  void _onDetect(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || !raw.startsWith(Invite.qrPrefix)) continue;
      final code = Invite.parse(raw);
      if (code == null || code == _code) continue;
      _codeController.text = code;
      if (_canJoin) _join();
      return;
    }
  }

  Future<void> _join() async {
    final code = _code;
    if (code == null) return;
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      final accepted = await widget.api.acceptInvite(code);
      try {
        await _scanner.stop();
      } catch (_) {}
      if (!mounted) return;
      Navigator.of(context).pop(accepted);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = switch (e.statusCode) {
          409 => 'You\'re already a member of that household.',
          _ => 'That code is invalid, expired, or already used.',
        };
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _joining = false;
        _error = 'Could not reach the server: $e';
      });
    }
  }

  @override
  void dispose() {
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
    final instructions = Text(
      'Ask whoever invited you for the code, or scan the QR they\'re shown.',
      style: theme.textTheme.bodyMedium,
    );
    final codeAndJoin = [
      TextField(
        controller: _codeController,
        textCapitalization: TextCapitalization.characters,
        decoration: const InputDecoration(labelText: 'Invite code', border: OutlineInputBorder()),
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      ],
      const SizedBox(height: 16),
      LoadingButton(loading: _joining, onPressed: _canJoin ? _join : null, label: 'Join household'),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Join a household')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          instructions,
          const SizedBox(height: 12),
          scanner,
          const SizedBox(height: 16),
          ...codeAndJoin,
        ],
      ),
    );
  }
}
