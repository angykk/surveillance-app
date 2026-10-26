from flask import Blueprint, abort, g, jsonify, request

import auth
import clip_storage
import db
import households
import signaling

bp = Blueprint('motion', __name__)

# Motion events come in over the camera's socket (see signaling.py); this is
# their HTTP side: the history behind the viewer's timeline, and what the
# camera attaches to each event, straight in clip storage (see
# clip_storage.py): a thumbnail of the moment motion started, uploaded right
# away, and the clip it records while the motion lasts, uploaded once it ends.

HISTORY_DEFAULT_LIMIT = 100
HISTORY_MAX_LIMIT = 500

_EVENT_COLUMNS = (
    'id, device_id, household_id, started_at, ended_at, clip_key, clip_size_bytes, thumb_key, thumb_size_bytes'
)

# What a camera can attach to one of its events: the key and size columns
# (the key is set on the first upload URL, the size once the upload is
# confirmed), and how the storage key is built.
_ATTACHMENTS = {
    'clip': ('clip_key', 'clip_size_bytes', clip_storage.clip_key),
    'thumbnail': ('thumb_key', 'thumb_size_bytes', clip_storage.thumbnail_key),
}


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
    device = households.device_or_404(device_id)
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
    thumbnail_urls = clip_storage.thumbnail_urls(rows)
    return jsonify([signaling.serialize_motion_event(row, thumbnail_urls.get(row['id'])) for row in rows])


def _own_event_or_404(event_id):
    """The calling camera's own event; a camera can't touch another's clips."""
    event = _event_or_404(event_id)
    if event['device_id'] != g.device['id']:
        abort(404)
    return event


@bp.route('/motion-events/<event_id>/<any(clip, thumbnail):kind>/upload', methods=['POST'])
@auth.require_device
def upload_url(event_id, kind):
    """Step one of attaching a clip or thumbnail: a signed URL the camera PUTs
    the file to, straight into storage. Can be asked for again (a retry)
    until the upload is marked done."""
    key_column, size_column, make_key = _ATTACHMENTS[kind]
    event = _own_event_or_404(event_id)
    if event[size_column] is not None:
        abort(409)
    key = event[key_column]
    if key is None:
        # Recorded before the upload, so retention and deletions clean the
        # object up even if the camera never reports it done.
        key = make_key(event)
        db.table('motion_events').update({key_column: key}).eq('id', event_id).execute()
    return jsonify({'url': clip_storage.get().upload_url(key)})


@bp.route('/motion-events/<event_id>/<any(clip, thumbnail):kind>/done', methods=['POST'])
@auth.require_device
def upload_done(event_id, kind):
    """Step two: the camera says the upload finished. It only counts once the
    object is actually in storage."""
    key_column, size_column, _ = _ATTACHMENTS[kind]
    event = _own_event_or_404(event_id)
    if event[size_column] is not None:
        abort(409)
    size_bytes = clip_storage.get().size(event[key_column]) if event[key_column] else None
    if size_bytes is None:
        abort(400)

    row = db.first(db.table('motion_events').update({size_column: size_bytes}).eq('id', event_id).execute())
    print(f"Stored {kind} for motion event {event_id} from camera '{g.device['name']}', {size_bytes} bytes")
    # Lets open timelines show the thumbnail, or turn the event playable.
    signaling.broadcast_motion(row)
    return '', 204


@bp.route('/motion-events/<event_id>/clip-url')
@auth.require_user
def clip_playback_url(event_id):
    """A short-lived URL the viewer's player streams the clip from directly
    (with Range requests, so it can scrub)."""
    event = _event_or_404(event_id)
    auth.require_member(event['household_id'])
    if event['clip_size_bytes'] is None:
        abort(404)
    return jsonify({'url': clip_storage.get().playback_url(event['clip_key'])})
