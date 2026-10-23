import os

from flask import Blueprint, abort, current_app, g, jsonify, request, send_from_directory

import auth
import db
import signaling

bp = Blueprint('motion', __name__)

# Motion events come in over the camera's socket (see signaling.py); this is
# their HTTP side: the history behind the viewer's timeline, and each event's
# clip, which the camera records while the motion lasts and uploads once it
# ends. Clip files sit on disk under RECORDINGS_DIR, one subfolder per device
# id. Device ids are server-issued, so they're always safe as directory names.

HISTORY_DEFAULT_LIMIT = 100
HISTORY_MAX_LIMIT = 500

_EVENT_COLUMNS = 'id, device_id, household_id, started_at, ended_at, clip_filename'


def _clips_dir():
    return current_app.config['RECORDINGS_DIR']


def _event_or_404(event_id):
    if not db.is_id(event_id):
        abort(404)
    row = db.first(db.table('motion_events').select(_EVENT_COLUMNS).eq('id', event_id).limit(1).execute())
    if row is None:
        abort(404)
    return row


@bp.route('/devices/<device_id>/motion-events')
@auth.require_user
def list_motion_events(device_id):
    """A camera's motion history, newest first, for the viewer's timeline.
    Live updates arrive separately as `motion` socket events."""
    if not db.is_id(device_id):
        abort(404)
    device = db.first(
        db.table('devices').select('household_id').eq('id', device_id).is_('revoked_at', 'null').limit(1).execute()
    )
    if device is None:
        abort(404)
    auth.require_member(device['household_id'])

    limit = min(request.args.get('limit', HISTORY_DEFAULT_LIMIT, type=int), HISTORY_MAX_LIMIT)
    rows = (
        db.table('motion_events')
        .select(_EVENT_COLUMNS)
        .eq('device_id', device_id)
        .order('started_at', desc=True)
        .limit(max(limit, 1))
        .execute()
        .data
    )
    return jsonify([signaling.serialize_motion_event(row) for row in rows])


@bp.route('/motion-events/<event_id>/clip', methods=['POST'])
@auth.require_device
def upload_clip(event_id):
    event = _event_or_404(event_id)
    # A camera can only attach a clip to its own events, and only once.
    if event['device_id'] != g.device['id']:
        abort(404)
    if event['clip_filename'] is not None:
        abort(409)
    file = request.files.get('file')
    if file is None:
        abort(400)

    device_dir = os.path.join(_clips_dir(), event['device_id'])
    os.makedirs(device_dir, exist_ok=True)
    filename = f'{event_id}.mp4'
    path = os.path.join(device_dir, filename)
    file.save(path)
    size_bytes = os.path.getsize(path)

    row = db.first(
        db.table('motion_events')
        .update({'clip_filename': filename, 'clip_size_bytes': size_bytes})
        .eq('id', event_id)
        .execute()
    )
    print(f"Stored clip for motion event {event_id} from camera '{g.device['name']}', {size_bytes} bytes")
    # Lets open timelines turn the event into a playable one.
    signaling.broadcast_motion(row)
    return '', 204


@bp.route('/motion-events/<event_id>/clip')
@auth.require_user
def clip_file(event_id):
    event = _event_or_404(event_id)
    auth.require_member(event['household_id'])
    if event['clip_filename'] is None:
        abort(404)
    # send_from_directory handles Range requests, which is what lets
    # video_player seek/scrub instead of only playing from the start.
    return send_from_directory(os.path.join(_clips_dir(), event['device_id']), event['clip_filename'])
