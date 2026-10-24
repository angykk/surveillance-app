from flask import request
from flask_socketio import SocketIO, disconnect

import auth
import db
import livekit_rooms

socketio = SocketIO()

# Control plane between Camera devices and Viewer users. Live video itself
# goes through LiveKit (see livekit_rooms.py); this socket decides who may
# watch what and tells cameras when to join their room:
# - `watch-camera` is acked with a subscribe-only LiveKit grant for that
#   camera's room, and the first watcher sends the camera `stream-start` with
#   a publish-only grant;
# - once the last watcher stops (or drops off), the camera gets
#   `stream-stop` and leaves the room, so an unwatched camera doesn't keep
#   uploading video.
# Any number of viewers can watch one camera at once.
#
# Both sides authenticate in the Socket.IO `auth` payload (not query params,
# which end up in proxy/access logs):
# - cameras send `{'device_token': ...}` from QR pairing, which pins them to
#   exactly one household;
# - viewers send `{'token': <Supabase JWT>}`, and only ever see — and can
#   only watch — cameras in households they're a member of.
#
# A same-device reconnect (new sid) evicts the stale slot outright: Engine.IO's
# ping-timeout-based disconnect detection can take up to ~60s to notice a dead
# socket, and without eviction a stale sid would linger as the camera's
# connection and swallow control messages meant for the live one.
#
# Cameras also report motion (`motion-start` / `motion-end`), which is stored
# as a motion event and pushed live to the household's viewers as `motion`.
# `motion-start` acks with the event id, which the camera later uploads that
# event's clip against (see motion.py).
#
# This presence state is per-process, so the server must run as a single
# instance until it moves to Redis.
cameras = {}  # device_id -> {'sid': str, 'name': str, 'household_id': str, 'motion_event_id': str | None, 'streaming': bool}
viewers = {}  # viewer_sid -> {'user_id': str, 'households': set, 'watching': device_id | None}


def _roster(household_ids):
    """Every paired (non-revoked) camera in the given households, online or
    not — offline cameras stay listed so their motion history remains
    reachable."""
    if not household_ids:
        return []
    rows = (
        db.table('devices')
        .select('id, name, household_id, last_seen_at, households(name)')
        .in_('household_id', list(household_ids))
        .is_('revoked_at', 'null')
        .order('created_at')
        .execute()
        .data
    )
    return [
        {
            'id': row['id'],
            'name': row['name'],
            'household_id': row['household_id'],
            'household_name': row['households']['name'],
            'online': row['id'] in cameras,
            'last_seen_at': row['last_seen_at'],
        }
        for row in rows
    ]


def _send_roster(viewer_sid):
    viewer = viewers.get(viewer_sid)
    if viewer is not None:
        socketio.emit('cameras-list', _roster(viewer['households']), to=viewer_sid)


def _household_viewer_sids(household_id):
    return [sid for sid, viewer in list(viewers.items()) if household_id in viewer['households']]


def broadcast_roster(household_id):
    for viewer_sid in _household_viewer_sids(household_id):
        _send_roster(viewer_sid)


def refresh_user_memberships(user_id):
    """Re-reads a connected user's households (e.g. after they create one),
    so their live roster picks up the change without a reconnect."""
    households = auth.household_ids_of(user_id)
    for viewer_sid, viewer in list(viewers.items()):
        if viewer['user_id'] == user_id:
            viewer['households'] = households
            _send_roster(viewer_sid)


def device_renamed(device_id, household_id, name):
    camera = cameras.get(device_id)
    if camera is not None:
        camera['name'] = name
    broadcast_roster(household_id)


def device_revoked(device_id, household_id):
    """Kicks a just-revoked camera off immediately rather than waiting for
    it to reconnect; its token no longer passes `auth.device_for_token`, so
    it can't come back."""
    camera = cameras.pop(device_id, None)
    if camera is not None:
        _end_motion(device_id, camera)
        _detach_camera(device_id, notify_viewer=True)
        socketio.server.disconnect(camera['sid'], namespace='/')
    livekit_rooms.close_room(device_id)
    broadcast_roster(household_id)


def _set_last_seen(device_id):
    db.table('devices').update({'last_seen_at': db.now()}).eq('id', device_id).execute()


def _camera_id_of_sid(sid):
    for device_id, info in cameras.items():
        if info['sid'] == sid:
            return device_id
    return None


@socketio.on('connect')
def on_connect(auth_payload):
    auth_payload = auth_payload or {}

    if auth_payload.get('device_token'):
        device = auth.device_for_token(auth_payload['device_token'])
        if device is None:
            print(f"Rejecting camera connection {request.sid}: invalid or revoked device token")
            raise ConnectionRefusedError('device_revoked')

        stale = cameras.get(device['id'])
        if stale is not None and stale['sid'] != request.sid:
            print(f"Evicting stale camera {device['id']} ({stale['sid']}), replaced by {request.sid}")
            _end_motion(device['id'], stale)
            _detach_camera(device['id'], notify_viewer=True)
            disconnect(sid=stale['sid'])

        cameras[device['id']] = {
            'sid': request.sid,
            'name': device['name'],
            'household_id': device['household_id'],
            'motion_event_id': None,
            'streaming': False,
        }
        _set_last_seen(device['id'])
        print(f"Camera '{device['name']}' ({device['id']}) connected: {request.sid}")
        broadcast_roster(device['household_id'])
        return

    claims = auth.verify_user_token(auth_payload.get('token'))
    if claims is None:
        print(f"Rejecting connection {request.sid}: missing or invalid credentials")
        raise ConnectionRefusedError('unauthorized')

    user_id = auth.ensure_user(claims)
    viewers[request.sid] = {
        'user_id': user_id,
        'households': auth.household_ids_of(user_id),
        'watching': None,
    }
    print(f"Viewer {user_id} connected: {request.sid}")
    _send_roster(request.sid)


@socketio.on('disconnect')
def on_disconnect(*_):
    device_id = _camera_id_of_sid(request.sid)
    if device_id is not None:
        camera = cameras.pop(device_id)
        print(f"Camera '{camera['name']}' ({device_id}) disconnected: {request.sid}")
        _end_motion(device_id, camera)
        _detach_camera(device_id, notify_viewer=True)
        _set_last_seen(device_id)
        broadcast_roster(camera['household_id'])
        return

    viewer = viewers.pop(request.sid, None)
    if viewer is not None:
        print(f"Viewer disconnected: {request.sid}")
        _release_stream(viewer['watching'])


def _detach_camera(device_id, *, notify_viewer):
    """Clears any viewer currently watching `device_id`, optionally telling
    that viewer the camera is gone so it can reset its UI."""
    for viewer_sid, viewer in viewers.items():
        if viewer['watching'] == device_id:
            viewer['watching'] = None
            if notify_viewer:
                socketio.emit('peer-left', to=viewer_sid)


def _release_stream(device_id):
    """Tells a camera to leave its LiveKit room once nobody is watching it
    any more, so it isn't uploading video to an empty room."""
    camera = cameras.get(device_id)
    if camera is None or not camera['streaming']:
        return
    if any(viewer['watching'] == device_id for viewer in viewers.values()):
        return
    camera['streaming'] = False
    print(f"Camera '{camera['name']}' ({device_id}) has no viewers left; stopping stream")
    socketio.emit('stream-stop', to=camera['sid'])


@socketio.on('watch-camera')
def on_watch_camera(data):
    """Acks with a LiveKit grant for the camera's room, or nothing (plus
    `peer-left`) if the camera can't be watched."""
    viewer = viewers.get(request.sid)
    if viewer is None:
        return None
    device_id = (data or {}).get('camera_id')
    camera = cameras.get(device_id)
    # A camera outside the viewer's households gets the same answer as an
    # offline one, so device ids can't be probed across households.
    if camera is None or camera['household_id'] not in viewer['households']:
        print(f"Viewer {request.sid} can't watch camera {device_id!r}: offline or not theirs")
        socketio.emit('peer-left', to=request.sid)
        return None

    # Switching cameras releases the previous one, so it stops streaming if
    # this viewer was its last watcher.
    previous = viewer['watching']
    viewer['watching'] = device_id
    if previous != device_id:
        _release_stream(previous)

    print(f"Viewer {request.sid} watching camera '{camera['name']}' ({device_id})")
    if not camera['streaming']:
        camera['streaming'] = True
        socketio.emit('stream-start', livekit_rooms.camera_grant(device_id, camera['name']), to=camera['sid'])
    return livekit_rooms.viewer_grant(device_id, viewer['user_id'], request.sid)


@socketio.on('stop-watching')
def on_stop_watching():
    viewer = viewers.get(request.sid)
    if viewer is None:
        return
    previous = viewer['watching']
    viewer['watching'] = None
    _release_stream(previous)


def serialize_motion_event(row):
    return {
        'id': row['id'],
        'camera_id': row['device_id'],
        'started_at': row['started_at'],
        'ended_at': row['ended_at'],
        'has_clip': row.get('clip_filename') is not None,
    }


def broadcast_motion(row):
    event = serialize_motion_event(row)
    for viewer_sid in _household_viewer_sids(row['household_id']):
        socketio.emit('motion', event, to=viewer_sid)


def _end_motion(device_id, camera):
    """Closes the camera's open motion event, if any. Also runs when a camera
    drops off, so an event is never left "ongoing" forever."""
    event_id = camera.get('motion_event_id')
    if event_id is None:
        return
    camera['motion_event_id'] = None
    row = db.first(
        db.table('motion_events').update({'ended_at': db.now()}).eq('id', event_id).is_('ended_at', 'null').execute()
    )
    if row is not None:
        print(f"Motion ended on camera '{camera['name']}' ({device_id})")
        broadcast_motion(row)


@socketio.on('motion-start')
def on_motion_start():
    device_id = _camera_id_of_sid(request.sid)
    if device_id is None:
        return
    camera = cameras[device_id]
    if camera['motion_event_id'] is not None:
        return {'id': camera['motion_event_id']}

    row = db.first(db.table('motion_events').insert({
        'id': db.new_id(),
        'device_id': device_id,
        'household_id': camera['household_id'],
        'started_at': db.now(),
        'ended_at': None,
    }).execute())
    camera['motion_event_id'] = row['id']
    print(f"Motion started on camera '{camera['name']}' ({device_id})")
    broadcast_motion(row)
    return {'id': row['id']}


@socketio.on('motion-end')
def on_motion_end():
    device_id = _camera_id_of_sid(request.sid)
    if device_id is not None:
        _end_motion(device_id, cameras[device_id])
