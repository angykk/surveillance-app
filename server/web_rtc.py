import os
import sqlite3
import time
import uuid

from flask import Flask, abort, jsonify, request, send_from_directory
from flask_socketio import SocketIO, disconnect

app = Flask(__name__)
socketio = SocketIO(app, async_mode="threading", cors_allowed_origins="*")

# Recording storage: motion clips are uploaded here by camera devices (see
# `_stopMotionRecording` in the mobile app) and served back out to viewers,
# rather than only ever living on the camera's own local storage — which is
# what made them unreachable from Viewer Mode before this. Metadata lives in
# SQLite; clip files sit on disk under RECORDINGS_DIR, one subfolder per
# camera_id so filenames only need to be unique per camera.
DATA_DIR = os.path.join(os.path.dirname(__file__), 'data')
RECORDINGS_DIR = os.path.join(DATA_DIR, 'recordings')
DB_PATH = os.path.join(DATA_DIR, 'recordings.db')
os.makedirs(RECORDINGS_DIR, exist_ok=True)


def _db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def _init_db():
    with _db() as conn:
        conn.execute('''
            CREATE TABLE IF NOT EXISTS recordings (
                id TEXT PRIMARY KEY,
                camera_id TEXT NOT NULL,
                camera_name TEXT NOT NULL,
                filename TEXT NOT NULL,
                created_at REAL NOT NULL,
                size_bytes INTEGER NOT NULL
            )
        ''')


_init_db()


@app.route('/recordings', methods=['POST'])
def upload_recording():
    camera_id = request.form.get('camera_id')
    camera_name = request.form.get('camera_name') or camera_id
    file = request.files.get('file')
    if not camera_id or file is None:
        abort(400)

    recording_id = uuid.uuid4().hex
    camera_dir = os.path.join(RECORDINGS_DIR, camera_id)
    os.makedirs(camera_dir, exist_ok=True)
    filename = f'{recording_id}.mp4'
    file.save(os.path.join(camera_dir, filename))
    size_bytes = os.path.getsize(os.path.join(camera_dir, filename))
    created_at = time.time()

    with _db() as conn:
        conn.execute(
            'INSERT INTO recordings (id, camera_id, camera_name, filename, created_at, size_bytes) '
            'VALUES (?, ?, ?, ?, ?, ?)',
            (recording_id, camera_id, camera_name, filename, created_at, size_bytes),
        )

    print(f"Stored recording {recording_id} from camera '{camera_name}' ({camera_id}), {size_bytes} bytes")
    return jsonify({'id': recording_id}), 201


@app.route('/recordings', methods=['GET'])
def list_recordings():
    camera_id = request.args.get('camera_id')
    with _db() as conn:
        if camera_id:
            rows = conn.execute(
                'SELECT * FROM recordings WHERE camera_id = ? ORDER BY created_at DESC', (camera_id,)
            ).fetchall()
        else:
            rows = conn.execute('SELECT * FROM recordings ORDER BY created_at DESC').fetchall()

    return jsonify([
        {
            'id': row['id'],
            'camera_id': row['camera_id'],
            'camera_name': row['camera_name'],
            'created_at': row['created_at'],
            'size_bytes': row['size_bytes'],
        }
        for row in rows
    ])


@app.route('/recordings/<recording_id>/file')
def recording_file(recording_id):
    with _db() as conn:
        row = conn.execute('SELECT * FROM recordings WHERE id = ?', (recording_id,)).fetchone()
    if row is None:
        abort(404)
    # send_from_directory handles Range requests, which is what lets
    # video_player seek/scrub instead of only playing from the start.
    return send_from_directory(os.path.join(RECORDINGS_DIR, row['camera_id']), row['filename'])


@app.route('/recordings/<recording_id>', methods=['DELETE'])
def delete_recording(recording_id):
    with _db() as conn:
        row = conn.execute('SELECT * FROM recordings WHERE id = ?', (recording_id,)).fetchone()
        if row is None:
            abort(404)
        conn.execute('DELETE FROM recordings WHERE id = ?', (recording_id,))

    path = os.path.join(RECORDINGS_DIR, row['camera_id'], row['filename'])
    if os.path.exists(path):
        os.remove(path)
    return '', 204

# Signaling relay between any number of Camera devices and any number of
# Viewer devices: offers/answers/ICE candidates are forwarded between a
# specific camera and whichever viewer is currently watching it, with no
# WebRTC peer or media handling on the server itself.
#
# Cameras register with a stable `camera_id` (persisted client-side) plus a
# human-readable `camera_name`, both sent as query params on connect. Viewers
# don't need an id at connect time — they receive the live camera roster and
# pick one via a `watch-camera` event, which is what actually pairs them with
# a camera for the offer/answer/ICE exchange below.
#
# A same-camera_id reconnect (new sid) evicts the stale slot outright, for
# the same reason as before: Engine.IO's ping-timeout-based disconnect
# detection can take up to ~60s to notice a dead socket, and without eviction
# a stale sid would linger as a phantom entry in the camera roster.
cameras = {}  # camera_id -> {'sid': str, 'name': str}
viewers = {}  # viewer_sid -> camera_id currently being watched, or None


def _camera_list():
    return [{'id': cid, 'name': info['name']} for cid, info in cameras.items()]


def _camera_id_of_sid(sid):
    for camera_id, info in cameras.items():
        if info['sid'] == sid:
            return camera_id
    return None


def _broadcast_camera_list():
    socketio.emit('cameras-list', _camera_list(), to=list(viewers.keys()))


@socketio.on('connect')
def on_connect():
    role = request.args.get('role')

    if role == 'camera':
        camera_id = request.args.get('camera_id')
        camera_name = request.args.get('camera_name') or camera_id
        if not camera_id:
            print(f"Rejecting camera connection {request.sid}: missing camera_id")
            return False

        stale = cameras.get(camera_id)
        if stale is not None and stale['sid'] != request.sid:
            print(f"Evicting stale camera {camera_id} ({stale['sid']}), replaced by {request.sid}")
            _detach_camera(camera_id, notify_viewer=True)
            disconnect(sid=stale['sid'])

        cameras[camera_id] = {'sid': request.sid, 'name': camera_name}
        print(f"Camera '{camera_name}' ({camera_id}) connected: {request.sid}")
        _broadcast_camera_list()

    elif role == 'viewer':
        viewers[request.sid] = None
        print(f"Viewer connected: {request.sid}")
        socketio.emit('cameras-list', _camera_list(), to=request.sid)

    else:
        print(f"Rejecting connection {request.sid}: invalid/missing role {role!r}")
        return False


@socketio.on('disconnect')
def on_disconnect():
    camera_id = _camera_id_of_sid(request.sid)
    if camera_id is not None:
        name = cameras[camera_id]['name']
        print(f"Camera '{name}' ({camera_id}) disconnected: {request.sid}")
        _detach_camera(camera_id, notify_viewer=True)
        del cameras[camera_id]
        _broadcast_camera_list()
        return

    if request.sid in viewers:
        print(f"Viewer disconnected: {request.sid}")
        _notify_camera_viewer_left(request.sid)
        del viewers[request.sid]


def _detach_camera(camera_id, *, notify_viewer):
    """Clears any viewer currently watching `camera_id`, optionally telling
    that viewer the camera is gone so it can reset its UI."""
    for viewer_sid, watching_id in viewers.items():
        if watching_id == camera_id:
            viewers[viewer_sid] = None
            if notify_viewer:
                socketio.emit('peer-left', to=viewer_sid)


def _notify_camera_viewer_left(viewer_sid):
    camera_id = viewers.get(viewer_sid)
    if camera_id is None:
        return
    camera = cameras.get(camera_id)
    if camera is not None:
        socketio.emit('peer-left', to=camera['sid'])


@socketio.on('watch-camera')
def on_watch_camera(data):
    if request.sid not in viewers:
        return
    camera_id = (data or {}).get('camera_id')
    camera = cameras.get(camera_id)
    if camera is None:
        print(f"Viewer {request.sid} tried to watch unknown camera {camera_id!r}")
        socketio.emit('peer-left', to=request.sid)
        return

    # Switching cameras (or re-picking the same one) first tells whichever
    # camera this viewer was previously watching that it left, so that
    # camera stops streaming instead of pushing to a viewer who's moved on.
    _notify_camera_viewer_left(request.sid)

    viewers[request.sid] = camera_id
    print(f"Viewer {request.sid} watching camera '{camera['name']}' ({camera_id})")
    socketio.emit('peer-joined', to=camera['sid'])


@socketio.on('stop-watching')
def on_stop_watching():
    if request.sid not in viewers:
        return
    _notify_camera_viewer_left(request.sid)
    viewers[request.sid] = None


def _relay_to_paired_peer(event, data):
    camera_id = _camera_id_of_sid(request.sid)
    if camera_id is not None:
        # Sender is a camera: relay to whichever viewer is currently
        # watching it (at most one, since each camera streams to a single
        # viewer at a time).
        for viewer_sid, watching_id in viewers.items():
            if watching_id == camera_id:
                socketio.emit(event, data, to=viewer_sid)
        return

    if request.sid in viewers:
        camera_id = viewers[request.sid]
        camera = cameras.get(camera_id)
        if camera is not None:
            socketio.emit(event, data, to=camera['sid'])


@socketio.on('offer')
def on_offer(data):
    print(f"Relaying offer from {request.sid}")
    _relay_to_paired_peer('offer', data)


@socketio.on('answer')
def on_answer(data):
    print(f"Relaying answer from {request.sid}")
    _relay_to_paired_peer('answer', data)


@socketio.on('icecandidate')
def on_icecandidate(data):
    print(f"Relaying ICE candidate from {request.sid}")
    _relay_to_paired_peer('icecandidate', data)


if __name__ == '__main__':
    socketio.run(app, host='0.0.0.0', port=5050, debug=True, allow_unsafe_werkzeug=True)
