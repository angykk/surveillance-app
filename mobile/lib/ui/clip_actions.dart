import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
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

/// Opens the system share sheet with a snapshot a camera took; on iOS it
/// has "Save Image" (into Photos). [origin] is as for [shareClip].
Future<void> shareSnapshot(
  BuildContext context, {
  required Uint8List jpeg,
  required String cameraName,
  required DateTime takenAt,
  required BuildContext origin,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final box = origin.findRenderObject() as RenderBox?;
  final originRect = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  try {
    // Cleared on each share, like shared clips.
    final dir = Directory('${(await getTemporaryDirectory()).path}/shared-snapshots');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final name = cameraName.replaceAll(RegExp(r'[^\w-]+'), '-');
    final file = File('${dir.path}/$name-${DateFormat('yyyyMMdd-HHmmss').format(takenAt)}.jpg');
    await file.writeAsBytes(jpeg);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path, mimeType: 'image/jpeg')], sharePositionOrigin: originRect),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not share snapshot: $e')));
  }
}

/// Asks before deleting an event; true if the user confirmed.
Future<bool> confirmDeleteEvent(BuildContext context) => showConfirmDialog(
      context,
      title: 'Delete this event?',
      message: 'Its clip and thumbnail are removed for everyone in the household.',
      confirmLabel: 'Delete',
    );
