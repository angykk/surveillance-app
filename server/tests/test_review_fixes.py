import importlib
import io
import json
import os
import re
import sys
import threading

import flask
import pytest

import clip_storage
import db
import retention
import signaling
import app as server_app
from conftest import as_device, as_user, pair_camera
from test_signaling import _connect_camera, _connect_viewer, _watch

SERVER_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

_OVERRIDE_KEYS = (
    'SQLITE_PATH', 'RECORDINGS_DIR', 'SUPABASE_JWT_SECRET',
    'LIVEKIT_URL', 'LIVEKIT_API_KEY', 'LIVEKIT_API_SECRET', 'TESTING',
)


def _overrides(app, **changes):
    """The `app` fixture's config, to build another app on the same database
    (e.g. a restarted server)."""
    return {**{k: app.config[k] for k in _OVERRIDE_KEYS}, **changes}


def _history(client, user_id, device_id):
    return client.get(f'/devices/{device_id}/motion-events', headers=as_user(user_id)).get_json()


def _stored_files(app):
    return [name for _, _, names in os.walk(app.config['RECORDINGS_DIR']) for name in names]


# Motion events left open by a restart.

def test_restart_closes_motion_events_left_open(app, client):
    cam = pair_camera(client, 'alice')
    camera = _connect_camera(app, cam['device_token'])
    camera.emit('motion-start')
    # The process dies mid-motion: the in-memory state is gone, the row isn't.
    signaling.cameras.clear()
    signaling.viewers.clear()
    [event] = _history(client, 'alice', cam['device_id'])
    assert event['ended_at'] is None

    restarted = server_app.create_app(_overrides(app)).test_client()
    [event] = _history(restarted, 'alice', cam['device_id'])
    assert event['ended_at'] is not None


def test_restart_leaves_finished_events_alone(app, client):
    cam = pair_camera(client, 'alice')
    camera = _connect_camera(app, cam['device_token'])
    camera.emit('motion-start')
    camera.emit('motion-end')
    [before] = _history(client, 'alice', cam['device_id'])

    restarted = server_app.create_app(_overrides(app)).test_client()
    assert _history(restarted, 'alice', cam['device_id']) == [before]


# Shared presence state touched from several threads.

def test_every_socket_handler_holds_the_state_lock():
    """Guards new handlers too: one without the lock can change `cameras` or
    `viewers` while another thread is iterating them."""
    with open(signaling.__file__) as f:
        source = f.read()
    handlers = re.findall(r"@socketio\.on\('([^']+)'\)\n(@_locked\n)?def ", source)
    assert handlers
    assert [event for event, locked in handlers if not locked] == []


def test_connects_from_other_threads_wait_for_the_state_lock(app, client, monkeypatch):
    cam = pair_camera(client, 'alice')
    _connect_camera(app, cam['device_token'])
    alice = _connect_viewer(app, 'alice')
    _watch(alice, cam['device_id'])

    # While revoking walks `viewers` to tell watchers the camera is gone, a
    # second viewer connects on another thread. It has to wait, rather than
    # add to `viewers` mid-iteration.
    late_viewer = threading.Thread(target=_connect_viewer, args=(app, 'alice'))
    blocked = []
    emit = signaling.socketio.emit

    def emit_and_race(event, *args, **kwargs):
        if event == 'peer-left' and not late_viewer.is_alive():
            late_viewer.start()
            late_viewer.join(timeout=0.3)
            blocked.append(late_viewer.is_alive())
        return emit(event, *args, **kwargs)

    monkeypatch.setattr(signaling.socketio, 'emit', emit_and_race)
    assert client.delete(f"/devices/{cam['device_id']}", headers=as_user('alice')).status_code == 204

    late_viewer.join(timeout=5)
    assert blocked == [True]
    assert not late_viewer.is_alive()
    assert len(signaling.viewers) == 2


# Same-device reconnects.

def test_camera_reconnect_never_shows_it_offline(app, client):
    cam = pair_camera(client, 'alice')
    stale = _connect_camera(app, cam['device_token'])
    alice = _connect_viewer(app, 'alice')
    alice.get_received()

    fresh = _connect_camera(app, cam['device_token'])
    rosters = [m['args'][0] for m in alice.get_received() if m['name'] == 'cameras-list']
    assert rosters
    assert all(c['online'] for roster in rosters for c in roster)
    assert not stale.is_connected()
    assert fresh.is_connected()


def test_camera_reconnect_closes_the_stale_connections_motion_and_viewers(app, client):
    cam = pair_camera(client, 'alice')
    stale = _connect_camera(app, cam['device_token'])
    alice = _connect_viewer(app, 'alice')
    _watch(alice, cam['device_id'])
    stale.emit('motion-start')
    alice.get_received()

    _connect_camera(app, cam['device_token'])
    received = alice.get_received()
    assert 'peer-left' in [m['name'] for m in received]
    [ended] = [m['args'][0] for m in received if m['name'] == 'motion']
    assert ended['ended_at'] is not None
    [event] = _history(client, 'alice', cam['device_id'])
    assert event['ended_at'] is not None


# Config parsing.

def test_blank_max_upload_mb_falls_back_to_the_default(app, monkeypatch):
    monkeypatch.setenv('MAX_UPLOAD_MB', '')
    rebuilt = server_app.create_app(_overrides(app))
    assert rebuilt.config['MAX_CONTENT_LENGTH'] == 200 * 1024 * 1024


def test_relative_paths_resolve_against_the_server_dir(app, tmp_path, monkeypatch):
    server_dir = tmp_path / 'server'
    elsewhere = tmp_path / 'elsewhere'
    elsewhere.mkdir()
    monkeypatch.setattr(server_app, 'SERVER_DIR', str(server_dir))
    monkeypatch.chdir(elsewhere)

    rebuilt = server_app.create_app(_overrides(app, SQLITE_PATH='data/local.db', RECORDINGS_DIR='data/recordings'))
    assert rebuilt.config['RECORDINGS_DIR'] == str(server_dir / 'data' / 'recordings')
    assert (server_dir / 'data' / 'recordings').is_dir()
    assert (server_dir / 'data' / 'local.db').is_file()
    assert list(elsewhere.iterdir()) == []


# Production server.

def test_docker_image_runs_gunicorn_with_a_single_worker():
    with open(os.path.join(SERVER_DIR, 'Dockerfile')) as f:
        cmd = json.loads(re.search(r'^CMD (\[.*\])$', f.read(), re.M).group(1))
    assert cmd[0] == 'gunicorn'
    assert cmd[cmd.index('--workers') + 1] == '1'
    assert cmd[-1] == 'wsgi:app'
    with open(os.path.join(SERVER_DIR, 'requirements.txt')) as f:
        assert any(line.startswith('gunicorn') for line in f)


def test_wsgi_module_builds_the_app(app, monkeypatch):
    for key, value in _overrides(app).items():
        if key != 'TESTING':
            monkeypatch.setenv(key, str(value))
    # Kept off this test's environment and database: the real .env, and the
    # retention thread a non-test app starts.
    monkeypatch.setattr('dotenv.load_dotenv', lambda *a, **k: None)
    monkeypatch.setattr(retention, 'start', lambda app: None)
    monkeypatch.delitem(sys.modules, 'wsgi', raising=False)

    wsgi = importlib.import_module('wsgi')
    assert isinstance(wsgi.app, flask.Flask)
    assert 'clip_storage' in wsgi.app.extensions


# Local clip uploads.

def _motion_event(app, device_token):
    camera = _connect_camera(app, device_token)
    event_id = camera.emit('motion-start', callback=True)['id']
    camera.emit('motion-end')
    return event_id


def test_upload_after_its_event_was_deleted_is_refused(app, client):
    cam = pair_camera(client, 'alice')
    event_id = _motion_event(app, cam['device_token'])
    url = client.post(f'/motion-events/{event_id}/clip/upload', headers=as_device(cam['device_token'])).get_json()['url']
    db.table('motion_events').delete().eq('id', event_id).execute()
    retention.run_once(0, app.extensions['clip_storage'])

    assert client.put(url, data=b'late clip', content_type='video/mp4').status_code == 404
    assert _stored_files(app) == []


class _DroppedUpload(io.RawIOBase):
    """A request stream that dies after its first chunk."""

    def __init__(self):
        self._sent = False

    def read(self, size=-1):
        if self._sent:
            raise ConnectionResetError('client went away')
        self._sent = True
        return b'first part of the clip'


def test_dropped_upload_leaves_no_partial_clip(app, client):
    cam = pair_camera(client, 'alice')
    event_id = _motion_event(app, cam['device_token'])
    headers = as_device(cam['device_token'])
    client.post(f'/motion-events/{event_id}/clip/upload', headers=headers)
    [event] = _history(client, 'alice', cam['device_id'])
    key = db.first(db.table('motion_events').select('clip_key').eq('id', event['id']).execute())['clip_key']

    with pytest.raises(ConnectionResetError):
        app.extensions['clip_storage'].save(key, _DroppedUpload())
    assert _stored_files(app) == []
    # So the camera can't mark the half-sent clip done; it has to retry.
    assert client.post(f'/motion-events/{event_id}/clip/done', headers=headers).status_code == 400


def test_completed_upload_replaces_an_earlier_one(app):
    storage = app.extensions['clip_storage']
    assert isinstance(storage, clip_storage.LocalStorage)
    storage.save('households/h/devices/d/e.mp4', io.BytesIO(b'first'))
    storage.save('households/h/devices/d/e.mp4', io.BytesIO(b'second try'))
    assert storage.size('households/h/devices/d/e.mp4') == len(b'second try')
    assert _stored_files(app) == ['e.mp4']
