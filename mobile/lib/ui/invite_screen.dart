import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../api/households_api.dart';
import 'app_theme.dart';
import 'shared_widgets.dart';

/// "Invite someone": lets an owner or admin mint a code for another person
/// to join this household as an admin or a viewer (redeemed at
/// AcceptInviteScreen), and manage the invites still outstanding.
class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key, required this.api, required this.household});

  final HouseholdsApi api;
  final Household household;

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  List<Invite>? _invites;
  String? _loadError;
  Invite? _justCreated;
  String _role = 'viewer';
  bool _creating = false;
  String? _createError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final invites = await widget.api.listInvites(widget.household.id);
      if (mounted) {
        setState(() {
          _invites = invites;
          _loadError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadError = 'Could not load invites: $e');
    }
  }

  Future<void> _create() async {
    setState(() {
      _creating = true;
      _createError = null;
    });
    try {
      final invite = await widget.api.createInvite(widget.household.id, _role);
      if (!mounted) return;
      setState(() {
        _creating = false;
        _justCreated = invite;
        _invites = [invite, ...?_invites];
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _creating = false;
          _createError = 'Could not create an invite: $e';
        });
      }
    }
  }

  Future<void> _revoke(Invite invite) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Cancel this invite?',
      message: 'The code ${_formatCode(invite.code)} will stop working.',
      confirmLabel: 'Cancel invite',
    );
    if (!confirmed) return;
    try {
      await widget.api.revokeInvite(widget.household.id, invite.code);
      if (!mounted) return;
      setState(() {
        _invites = _invites?.where((i) => i.code != invite.code).toList();
        if (_justCreated?.code == invite.code) _justCreated = null;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not cancel the invite: $e')));
    }
  }

  void _share(Invite invite) {
    SharePlus.instance.share(ShareParams(
      text: 'Join "${widget.household.name}" on KeepWatch: in the app, go to Join a household and enter '
          'this code: ${invite.code}',
    ));
  }

  static String _formatCode(String code) => '${code.substring(0, 4)}-${code.substring(4)}';

  static String _expiresLabel(DateTime expiresAt) {
    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.isNegative) return 'Expired';
    if (remaining.inDays >= 1) return 'Expires in ${remaining.inDays}d';
    if (remaining.inHours >= 1) return 'Expires in ${remaining.inHours}h';
    return 'Expires soon';
  }

  @override
  Widget build(BuildContext context) {
    final justCreated = _justCreated;
    return Scaffold(
      appBar: AppBar(title: Text('Invite to ${widget.household.name}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (justCreated != null) ...[
            _buildJustCreated(context, justCreated),
            const SizedBox(height: 24),
          ],
          _buildCreateForm(context),
          const SizedBox(height: 32),
          Text('Pending invites', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _buildPendingList(context),
        ],
      ),
    );
  }

  Widget _buildJustCreated(BuildContext context, Invite invite) {
    final theme = Theme.of(context);
    final qr = Container(
      // QR scanners need dark-on-light with a quiet zone, whatever the
      // app's theme is.
      color: AppColors.white,
      padding: const EdgeInsets.all(16),
      child: QrImageView(data: invite.qrPayload, size: 180),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text('Share this with ${invite.role == 'admin' ? 'the new admin' : 'the new viewer'}',
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            qr,
            const SizedBox(height: 12),
            SelectableText(
              _formatCode(invite.code),
              style: theme.textTheme.headlineSmall?.copyWith(fontFamily: 'monospace', letterSpacing: 3),
            ),
            const SizedBox(height: 4),
            Text(_expiresLabel(invite.expiresAt), style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => _share(invite),
              icon: const Icon(Icons.share),
              label: const Text('Share'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCreateForm(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('New invite', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'viewer', label: Text('Viewer'), icon: Icon(Icons.visibility_outlined)),
                ButtonSegment(value: 'admin', label: Text('Admin'), icon: Icon(Icons.admin_panel_settings_outlined)),
              ],
              selected: {_role},
              onSelectionChanged: (selected) => setState(() => _role = selected.single),
            ),
            const SizedBox(height: 8),
            Text(
              _role == 'admin'
                  ? 'Can add, rename and remove cameras, and invite others.'
                  : 'Can watch cameras and their motion history only.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_createError != null) ...[
              const SizedBox(height: 12),
              Text(_createError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 16),
            LoadingButton(loading: _creating, onPressed: _create, label: 'Create invite code'),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingList(BuildContext context) {
    if (_loadError != null) return Text(_loadError!, style: TextStyle(color: Theme.of(context).colorScheme.error));
    final invites = _invites;
    if (invites == null) return const Center(child: CircularProgressIndicator());
    if (invites.isEmpty) return const Text('No invites are outstanding.');
    return Column(
      children: [
        for (final invite in invites)
          Card(
            child: ListTile(
              leading: Icon(invite.role == 'admin' ? Icons.admin_panel_settings_outlined : Icons.visibility_outlined),
              title: Text(_formatCode(invite.code), style: const TextStyle(fontFamily: 'monospace')),
              subtitle: Text('${invite.role == 'admin' ? 'Admin' : 'Viewer'} · ${_expiresLabel(invite.expiresAt)}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(icon: const Icon(Icons.share_outlined), tooltip: 'Share', onPressed: () => _share(invite)),
                  IconButton(
                    icon: const Icon(Icons.cancel_outlined),
                    tooltip: 'Cancel invite',
                    onPressed: () => _revoke(invite),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
