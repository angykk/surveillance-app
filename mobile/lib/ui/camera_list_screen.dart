import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/households_api.dart';
import '../auth/session.dart';
import '../api/motion_api.dart';
import '../config.dart';
import '../webrtc/signaling_client.dart';
import 'pairing_code_screen.dart';
import 'theme_controller.dart';
import 'viewer_screen.dart';

class CameraInfo {
  const CameraInfo({
    required this.id,
    required this.name,
    required this.householdId,
    required this.householdName,
    required this.online,
    required this.lastSeenAt,
  });

  final String id;
  final String name;
  final String householdId;
  final String householdName;
  final bool online;

  /// When the camera last connected or disconnected; null if it never has.
  final DateTime? lastSeenAt;

  factory CameraInfo.fromJson(Map<dynamic, dynamic> json) => CameraInfo(
        id: json['id'] as String,
        name: json['name'] as String,
        householdId: json['household_id'] as String,
        householdName: json['household_name'] as String,
        online: json['online'] as bool,
        lastSeenAt: json['last_seen_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(((json['last_seen_at'] as num) * 1000).round()),
      );
}

/// Viewer Mode's home once signed in: every camera paired into the user's
/// households, live-updated by the server. Owns the one [SignalingClient]
/// socket for the viewer's whole session — picking a camera pushes a
/// [ViewerScreen] that reuses this same socket rather than opening a new
/// connection, so switching cameras doesn't mean a full reconnect.
class CameraListScreen extends StatefulWidget {
  const CameraListScreen({super.key, required this.themeController, required this.onSwitchMode});

  final ThemeController themeController;

  /// Leaves Viewer Mode for the mode picker.
  final VoidCallback onSwitchMode;

  @override
  State<CameraListScreen> createState() => _CameraListScreenState();
}

class _CameraListScreenState extends State<CameraListScreen> with WidgetsBindingObserver {
  late final SignalingClient _signaling;
  late final _api = ApiClient.forUser(AppConfig.serverUrl);
  late final _householdsApi = HouseholdsApi(_api);
  late final _motionApi = MotionApi(_api);

  List<CameraInfo> _cameras = [];
  Map<String, Household> _households = {};
  bool _connected = false;
  String? _connectError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _signaling = SignalingClient(
      AppConfig.serverUrl,
      auth: () async => {'token': await freshAccessToken()},
    );

    _signaling.socket.on('connect', (_) {
      if (mounted) {
        setState(() {
          _connected = true;
          _connectError = null;
        });
      }
    });
    _signaling.socket.on('disconnect', (_) {
      if (mounted) setState(() => _connected = false);
    });
    _signaling.socket.on('connect_error', (data) {
      // A server refusal (rather than a network blip, which
      // socket_io_client retries on its own) ends the connection for good,
      // so it needs surfacing with a manual retry.
      if (SignalingClient.refusalReason(data) != null && mounted) {
        setState(() => _connectError = 'The server didn\'t accept your sign-in. Try again, or sign out and back in.');
      }
    });
    _signaling.socket.on('cameras-list', (data) {
      final list = (data as List).cast<Map>().map(CameraInfo.fromJson).toList()
        ..sort((a, b) {
          final byHousehold = a.householdName.compareTo(b.householdName);
          return byHousehold != 0 ? byHousehold : a.name.compareTo(b.name);
        });
      if (mounted) setState(() => _cameras = list);
      // A camera can appear in a household this screen hasn't loaded yet
      // (e.g. created since); refresh so its role is known.
      if (list.any((c) => !_households.containsKey(c.householdId))) _loadHouseholds();
    });

    _signaling.socket.connect();
    _loadHouseholds();
  }

  Future<void> _loadHouseholds() async {
    try {
      final households = await _householdsApi.households();
      if (mounted) setState(() => _households = {for (final h in households) h.id: h});
    } catch (e) {
      debugPrint('Loading households failed: $e');
    }
  }

  void _reconnect() {
    setState(() => _connectError = null);
    _signaling.socket.connect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _signaling.socket.disconnect();
    } else if (state == AppLifecycleState.resumed && _signaling.socket.disconnected) {
      _signaling.socket.connect();
    }
  }

  bool _canManage(CameraInfo camera) => _households[camera.householdId]?.canManage ?? false;

  Future<void> _openCamera(CameraInfo camera) async {
    // Offline cameras open the same screen: their motion timeline is still
    // there, and the stream starts once they come back.
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ViewerScreen(signaling: _signaling, camera: camera, motionApi: _motionApi),
      ),
    );
  }

  Future<void> _addCamera() async {
    final manageable = _households.values.where((h) => h.canManage).toList();
    if (manageable.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only household owners and admins can add cameras.')),
      );
      return;
    }
    final household = manageable.length == 1
        ? manageable.single
        : await showModalBottomSheet<Household>(
            context: context,
            builder: (context) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ListTile(title: Text('Add camera to…')),
                  for (final h in manageable)
                    ListTile(
                      leading: const Icon(Icons.home_outlined),
                      title: Text(h.name),
                      onTap: () => Navigator.of(context).pop(h),
                    ),
                ],
              ),
            ),
          );
    if (household == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PairingCodeScreen(api: _householdsApi, household: household)),
    );
  }

  Future<void> _renameCamera(CameraInfo camera) async {
    final controller = TextEditingController(text: camera.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Camera name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Save')),
        ],
      ),
    );
    final trimmed = newName?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == camera.name) return;
    await _runAction(() => _householdsApi.renameCamera(camera.id, trimmed), 'Rename failed');
  }

  Future<void> _removeCamera(CameraInfo camera) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${camera.name}?'),
        content: const Text(
          'It will be disconnected right away and must be paired again to rejoin.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _runAction(() => _householdsApi.removeCamera(camera.id), 'Remove failed');
  }

  /// The roster updates itself from the server once these succeed, so only
  /// failures need handling here.
  Future<void> _runAction(Future<void> Function() action, String failureLabel) async {
    try {
      await action();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$failureLabel: $e')));
    }
  }

  Future<void> _confirmSwitchMode() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Switch modes?'),
        content: const Text('This device will stop being a viewer and go back to the mode picker. You\'ll stay signed in.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Switch')),
        ],
      ),
    );
    if (confirmed == true) widget.onSwitchMode();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _signaling.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cameras'),
        actions: [
          _ThemeModeMenu(themeController: widget.themeController),
          PopupMenuButton<_SettingsAction>(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onSelected: (action) {
              switch (action) {
                case _SettingsAction.signOut:
                  supabase.auth.signOut();
                case _SettingsAction.switchMode:
                  _confirmSwitchMode();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _SettingsAction.signOut,
                child: ListTile(
                  leading: const Icon(Icons.logout),
                  title: const Text('Sign out'),
                  subtitle: supabase.auth.currentUser?.email == null ? null : Text(supabase.auth.currentUser!.email!),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: _SettingsAction.switchMode,
                child: ListTile(
                  leading: Icon(Icons.swap_horiz),
                  title: Text('Switch mode'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: _connected
          ? FloatingActionButton.extended(
              onPressed: _addCamera,
              icon: const Icon(Icons.add),
              label: const Text('Add camera'),
            )
          : null,
      body: _connectError != null
          ? _CenteredMessage(
              icon: Icons.cloud_off_outlined,
              message: _connectError!,
              action: ElevatedButton(onPressed: _reconnect, child: const Text('Try again')),
            )
          : !_connected
              ? const Center(child: CircularProgressIndicator())
              : _cameras.isEmpty
                  ? const _CenteredMessage(
                      icon: Icons.videocam_off_outlined,
                      message: 'No cameras yet.\nTap “Add camera”, then scan the code from a phone in Camera Mode.',
                    )
                  : _buildCameras(context),
    );
  }

  /// A list in portrait; a grid of the same cards when the screen is wide
  /// (landscape or a tablet), so they don't stretch across the whole width.
  Widget _buildCameras(BuildContext context) {
    const padding = EdgeInsets.fromLTRB(12, 8, 12, 88);
    if (MediaQuery.sizeOf(context).width >= 600) {
      return GridView.builder(
        padding: padding,
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 420,
          mainAxisExtent: 88,
          crossAxisSpacing: 8,
        ),
        itemCount: _cameras.length,
        itemBuilder: (context, index) => _cameraCard(_cameras[index]),
      );
    }
    return ListView.builder(
      padding: padding,
      itemCount: _cameras.length,
      itemBuilder: (context, index) => _cameraCard(_cameras[index]),
    );
  }

  Widget _cameraCard(CameraInfo camera) {
    final showHouseholds = _cameras.map((c) => c.householdId).toSet().length > 1;
    // Names are user-chosen, so two cameras can still share one — fall back
    // to a short id so they're distinguishable here.
    final isAmbiguous =
        _cameras.where((c) => c.name == camera.name && c.householdId == camera.householdId).length > 1;
    final status = [
      camera.online ? 'Online' : 'Offline',
      if (showHouseholds) camera.householdName,
      if (isAmbiguous) 'ID ${camera.id.substring(0, 8)}',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 16, right: 4, top: 4, bottom: 4),
        leading: _CameraLeadingIcon(online: camera.online),
        title: Text(camera.name, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(status),
        trailing: _canManage(camera)
            ? PopupMenuButton<String>(
                onSelected: (action) => action == 'rename' ? _renameCamera(camera) : _removeCamera(camera),
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'remove', child: Text('Remove camera')),
                ],
              )
            : const Icon(Icons.chevron_right),
        onTap: () => _openCamera(camera),
      ),
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.icon, required this.message, this.action});

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

/// A camera icon with a small status dot: green while the camera is
/// connected, grey while it's offline (its motion history is still reachable).
class _CameraLeadingIcon extends StatelessWidget {
  const _CameraLeadingIcon({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(Icons.videocam, size: 32, color: online ? null : colors.outline),
        Positioned(
          right: -2,
          bottom: -2,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: online ? Colors.green : colors.outline,
              shape: BoxShape.circle,
              border: Border.all(color: colors.surface, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}

/// AppBar action for picking the app's light/dark/system theme. Lives on
/// Viewer Mode's screens only — Camera Mode runs unattended, so there's no
/// one around to appreciate a theme switch there.
enum _SettingsAction { signOut, switchMode }

class _ThemeModeMenu extends StatelessWidget {
  const _ThemeModeMenu({required this.themeController});

  final ThemeController themeController;

  static const _labels = {
    ThemeMode.system: 'System default',
    ThemeMode.light: 'Light',
    ThemeMode.dark: 'Dark',
  };

  static const _icons = {
    ThemeMode.system: Icons.brightness_auto_outlined,
    ThemeMode.light: Icons.light_mode_outlined,
    ThemeMode.dark: Icons.dark_mode_outlined,
  };

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeController,
      builder: (context, mode, _) {
        return PopupMenuButton<ThemeMode>(
          icon: Icon(_icons[mode]),
          tooltip: 'Theme',
          initialValue: mode,
          onSelected: themeController.setMode,
          itemBuilder: (context) => ThemeMode.values
              .map(
                (m) => PopupMenuItem(
                  value: m,
                  child: Row(
                    children: [
                      Icon(_icons[m], size: 20),
                      const SizedBox(width: 12),
                      Text(_labels[m]!),
                      if (m == mode) ...[
                        const Spacer(),
                        const Icon(Icons.check, size: 18),
                      ],
                    ],
                  ),
                ),
              )
              .toList(),
        );
      },
    );
  }
}
