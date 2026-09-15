import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import '../webrtc/signaling_client.dart';
import 'viewer_screen.dart';

class CameraInfo {
  const CameraInfo({required this.id, required this.name});

  final String id;
  final String name;

  factory CameraInfo.fromJson(Map<dynamic, dynamic> json) =>
      CameraInfo(id: json['id'] as String, name: json['name'] as String);
}

/// Viewer Mode's entry point: connects to the signaling server as a viewer
/// and shows every camera currently registered there. Owns the one
/// [SignalingClient] socket for the viewer's whole session — picking a
/// camera pushes a [ViewerScreen] that reuses this same socket rather than
/// opening a new connection, so switching cameras doesn't mean a full
/// reconnect.
class CameraListScreen extends StatefulWidget {
  const CameraListScreen({super.key});

  @override
  State<CameraListScreen> createState() => _CameraListScreenState();
}

class _CameraListScreenState extends State<CameraListScreen> with WidgetsBindingObserver {
  late final SignalingClient _signaling;
  List<CameraInfo> _cameras = [];
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _signaling = SignalingClient(dotenv.env['SERVER_IP']!, role: 'viewer');

    _signaling.socket.on('connect', (_) {
      if (mounted) setState(() => _connected = true);
    });
    _signaling.socket.on('disconnect', (_) {
      if (mounted) setState(() => _connected = false);
    });
    _signaling.socket.on('cameras-list', (data) {
      final list = (data as List).cast<Map>().map(CameraInfo.fromJson).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      if (mounted) setState(() => _cameras = list);
    });

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

  Future<void> _openCamera(CameraInfo camera) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ViewerScreen(
          signaling: _signaling,
          camera: camera,
          serverUrl: dotenv.env['SERVER_IP']!,
        ),
      ),
    );
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
      appBar: AppBar(title: const Text('Cameras')),
      body: !_connected
          ? const Center(child: CircularProgressIndicator())
          : _cameras.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.videocam_off_outlined, size: 48, color: Colors.grey),
                        const SizedBox(height: 16),
                        const Text(
                          'No cameras online yet.\nStart a device in Camera Mode to see it here.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: _cameras.length,
                  itemBuilder: (context, index) {
                    final camera = _cameras[index];
                    // Cameras default to the generic name "Camera" until
                    // renamed (see CameraIdentity.isUnnamed), so more than
                    // one can show up identically named — fall back to a
                    // short id so they're still distinguishable here.
                    final isAmbiguous =
                        _cameras.where((c) => c.name == camera.name).length > 1;
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        leading: const _CameraLeadingIcon(),
                        title: Text(camera.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(isAmbiguous ? 'Online · ID ${camera.id.substring(0, 8)}' : 'Online'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openCamera(camera),
                      ),
                    );
                  },
                ),
    );
  }
}

/// A camera icon with a small green dot badge, signaling this camera is
/// currently online — every entry in this list is, since offline cameras
/// drop out of the roster entirely rather than being shown greyed out.
class _CameraLeadingIcon extends StatelessWidget {
  const _CameraLeadingIcon();

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(Icons.videocam, size: 32),
        Positioned(
          right: -2,
          bottom: -2,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: Colors.green,
              shape: BoxShape.circle,
              border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}
