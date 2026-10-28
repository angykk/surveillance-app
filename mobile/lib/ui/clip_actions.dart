import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../api/motion_api.dart';
import 'shared_widgets.dart';

/// Downloads [event]'s clip and opens the system share sheet with it. On
/// iOS the sheet has "Save Video" (into Photos); on Android it offers Files,
/// Drive, Photos and messaging apps. [origin] is the widget the sheet points
/// at on an iPad.
Future<void> shareClip(
  BuildContext context, {
  required MotionApi motionApi,
  required MotionEvent event,
  required String cameraName,
  required BuildContext origin,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final box = origin.findRenderObject() as RenderBox?;
  final originRect = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  messenger.showSnackBar(const SnackBar(content: Text('Preparing clip…'), duration: Duration(minutes: 5)));
  try {
    final file = await motionApi.downloadClip(event, cameraName);
    messenger.hideCurrentSnackBar();
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path, mimeType: 'video/mp4')], sharePositionOrigin: originRect),
    );
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Could not share clip: $e')));
  }
}

/// Asks before deleting an event; true if the user confirmed.
Future<bool> confirmDeleteEvent(BuildContext context) => showConfirmDialog(
      context,
      title: 'Delete this event?',
      message: 'Its clip and thumbnail are removed for everyone in the household.',
      confirmLabel: 'Delete',
    );
