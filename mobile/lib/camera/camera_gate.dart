import 'package:flutter/material.dart';

import 'camera_screen.dart';
import 'device_credentials.dart';
import 'pair_camera_screen.dart';

/// Camera Mode's entry point: runs the camera if this device is paired to a
/// household, otherwise walks through pairing first. Also where a camera
/// lands if it's removed from its household while running.
class CameraGate extends StatefulWidget {
  const CameraGate({super.key});

  @override
  State<CameraGate> createState() => _CameraGateState();
}

class _CameraGateState extends State<CameraGate> {
  DeviceCredentials? _credentials;
  bool _loading = true;
  String? _notice;

  @override
  void initState() {
    super.initState();
    DeviceCredentials.load().then((credentials) {
      if (!mounted) return;
      setState(() {
        _credentials = credentials;
        _loading = false;
      });
    });
  }

  Future<void> _onUnpaired() async {
    await DeviceCredentials.clear();
    if (!mounted) return;
    setState(() {
      _credentials = null;
      _notice = 'This camera was removed from its household. Pair it again to keep using it.';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final credentials = _credentials;
    if (credentials == null) {
      return PairCameraScreen(
        notice: _notice,
        onPaired: (c) => setState(() {
          _credentials = c;
          _notice = null;
        }),
      );
    }
    return CameraScreen(
      key: ValueKey(credentials.deviceId),
      credentials: credentials,
      onUnpaired: _onUnpaired,
    );
  }
}
