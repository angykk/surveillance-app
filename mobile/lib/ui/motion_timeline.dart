import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/motion_api.dart';
import '../motion/motion_label.dart';
import 'shared_widgets.dart';

/// How long after an event ends its clip is still expected to arrive; past
/// that, an event without one is shown as having no clip.
const _clipUploadGrace = Duration(minutes: 2);

/// A camera's motion events, newest first and grouped by day: when it last
/// saw movement and for how long. Events with a clip are tappable to play it;
/// each row's ⋮ menu (or a long-press) shares its clip or deletes it.
class MotionTimeline extends StatelessWidget {
  const MotionTimeline({
    super.key,
    required this.events,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.selectedId,
    required this.onSelect,
    required this.onShare,
    this.onDelete,
  });

  /// Newest first.
  final List<MotionEvent> events;
  final bool loading;
  final String? error;
  final Future<void> Function() onRefresh;

  /// The event whose clip is playing, highlighted in the list.
  final String? selectedId;
  final void Function(MotionEvent event) onSelect;

  /// Shares an event's clip; [origin] is the row, for the iPad share popover.
  final void Function(MotionEvent event, BuildContext origin) onShare;

  /// Deletes an event. Null when the user can't (only owners and admins
  /// can), which leaves Delete out of the menu.
  final void Function(MotionEvent event)? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget content;
    if (loading && events.isEmpty) {
      content = const Center(child: CircularProgressIndicator());
    } else if (error != null && events.isEmpty) {
      content = MessageView(
        message: error!,
        textColor: theme.colorScheme.outline,
        actionSpacing: 8,
        action: TextButton(onPressed: onRefresh, child: const Text('Retry')),
      );
    } else if (events.isEmpty) {
      content = MessageView(
        message: 'No motion yet.\nMovement this camera sees will show up here.',
        textColor: theme.colorScheme.outline,
      );
    } else {
      final rows = _rows();
      content = RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView.builder(
          padding: const EdgeInsets.only(bottom: 16),
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final row = rows[index];
            if (row is DateTime) return _DayHeader(day: row);
            final event = row as MotionEvent;
            return _EventTile(
              event: event,
              selected: event.id == selectedId,
              onTap: event.hasClip ? () => onSelect(event) : null,
              onShare: onShare,
              onDelete: onDelete,
            );
          },
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Motion', style: theme.textTheme.titleMedium),
        ),
        Expanded(child: content),
      ],
    );
  }

  /// Events interleaved with a header (the day, as a DateTime) wherever the
  /// day changes.
  List<Object> _rows() {
    final rows = <Object>[];
    DateTime? currentDay;
    for (final event in events) {
      final start = event.startedAt;
      final day = DateTime(start.year, start.month, start.day);
      if (day != currentDay) {
        rows.add(day);
        currentDay = day;
      }
      rows.add(event);
    }
    return rows;
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final label = switch (today.difference(day).inDays) {
      0 => 'Today',
      1 => 'Yesterday',
      _ => DateFormat(day.year == today.year ? 'EEE, MMM d' : 'MMM d, y').format(day),
    };
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(label, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
    );
  }
}

enum _EventAction { share, delete }

class _EventTile extends StatefulWidget {
  const _EventTile({
    required this.event,
    required this.selected,
    required this.onTap,
    required this.onShare,
    required this.onDelete,
  });

  final MotionEvent event;
  final bool selected;
  final VoidCallback? onTap;
  final void Function(MotionEvent event, BuildContext origin) onShare;
  final void Function(MotionEvent event)? onDelete;

  @override
  State<_EventTile> createState() => _EventTileState();
}

class _EventTileState extends State<_EventTile> {
  /// Lets a long-press open the same menu as the ⋮ button.
  final _menuKey = GlobalKey<PopupMenuButtonState<_EventAction>>();

  /// A share needs a clip; a delete needs the right role, and the motion to
  /// have ended (the camera is still recording into an ongoing event).
  List<PopupMenuEntry<_EventAction>> _menuItems() => [
        if (widget.event.hasClip)
          const PopupMenuItem(
            value: _EventAction.share,
            child: ListTile(leading: Icon(Icons.ios_share), title: Text('Share clip')),
          ),
        if (widget.onDelete != null)
          PopupMenuItem(
            value: _EventAction.delete,
            enabled: !widget.event.ongoing,
            child: const ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete')),
          ),
      ];

  void _onAction(_EventAction action) => switch (action) {
        _EventAction.share => widget.onShare(widget.event, context),
        _EventAction.delete => widget.onDelete?.call(widget.event),
      };

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final selected = widget.selected;
    final hasMenu = _menuItems().isNotEmpty;
    final colors = Theme.of(context).colorScheme;
    final endedAt = event.endedAt;
    final String? clipNote;
    if (event.ongoing) {
      clipNote = 'Recording…';
    } else if (event.hasClip) {
      clipNote = null;
    } else {
      clipNote = DateTime.now().difference(endedAt!) < _clipUploadGrace ? 'Saving clip…' : 'No clip';
    }
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: selected ? colors.secondaryContainer : Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: hasMenu ? () => _menuKey.currentState?.showButtonMenu() : null,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 6, hasMenu ? 0 : 16, 6),
          child: Row(
            children: [
              _Thumbnail(event: event),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          DateFormat.jm().format(event.startedAt),
                          style: textTheme.bodyLarge?.copyWith(color: selected ? colors.onSecondaryContainer : null),
                        ),
                        const SizedBox(width: 8),
                        _LabelTag(label: event.label),
                      ],
                    ),
                    if (clipNote != null)
                      Text(clipNote, style: textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                  ],
                ),
              ),
              Text(
                endedAt == null ? 'Ongoing' : _formatDuration(endedAt.difference(event.startedAt)),
                style: TextStyle(color: event.ongoing ? colors.error : colors.onSurfaceVariant),
              ),
              if (hasMenu)
                PopupMenuButton<_EventAction>(
                  key: _menuKey,
                  tooltip: 'Event actions',
                  icon: Icon(Icons.more_vert, color: colors.onSurfaceVariant),
                  itemBuilder: (_) => _menuItems(),
                  onSelected: _onAction,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the camera saw in an event: a person, a pet, or just motion.
class _LabelTag extends StatelessWidget {
  const _LabelTag({required this.label});

  final MotionLabel label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, text) = switch (label) {
      MotionLabel.person => (Icons.person, 'Person'),
      MotionLabel.pet => (Icons.pets, 'Pet'),
      MotionLabel.motion => (Icons.motion_photos_on_outlined, 'Motion'),
    };
    final color = label == MotionLabel.person ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 2),
        Text(text, style: theme.textTheme.labelSmall?.copyWith(color: color)),
      ],
    );
  }
}

/// The still of the moment motion started, with a pulsing dot while the
/// motion lasts and a play badge once there's a clip. Before the thumbnail
/// arrives (or if it never does, or its signed URL has expired) it shows a
/// placeholder icon instead.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.event});

  final MotionEvent event;

  static const _width = 96.0;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final placeholder = Center(child: Icon(Icons.directions_run, color: colors.outline));
    final url = event.thumbnailUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: _width,
        height: _width * 9 / 16,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: colors.surfaceContainerHighest),
            if (url == null)
              placeholder
            else
              Image.network(
                url.toString(),
                fit: BoxFit.cover,
                cacheWidth: (_width * MediaQuery.devicePixelRatioOf(context)).round(),
                // A refresh re-signs the URL; keep showing the old image
                // while the new one loads rather than flashing blank.
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => placeholder,
              ),
            if (event.ongoing)
              Positioned(top: 6, left: 6, child: PulsingDot(color: colors.error, size: 10)),
            if (event.hasClip)
              Center(
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.play_arrow, color: Colors.white, size: 20),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _formatDuration(Duration d) {
  if (d.inSeconds < 1) return '<1s';
  if (d.inMinutes < 1) return '${d.inSeconds}s';
  final seconds = d.inSeconds % 60;
  if (d.inHours < 1) return seconds == 0 ? '${d.inMinutes}m' : '${d.inMinutes}m ${seconds}s';
  return '${d.inHours}h ${d.inMinutes % 60}m';
}

/// A dot that fades in and out, marking motion that's happening right now.
class PulsingDot extends StatefulWidget {
  const PulsingDot({super.key, required this.color, this.size = 12});

  final Color color;
  final double size;

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.3, end: 1).animate(_controller),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}
