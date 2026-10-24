import time

import jwt
import pytest

import livekit_rooms
import signaling
from web_rtc import create_app

TEST_SECRET = 'test-secret-at-least-32-bytes-long!!'
LIVEKIT_SECRET = 'livekit-test-secret-at-least-32-bytes'


@pytest.fixture
def closed_rooms(monkeypatch):
    """Records `livekit_rooms.close_room` calls instead of contacting a
    LiveKit server."""
    closed = []
    monkeypatch.setattr(livekit_rooms, 'close_room', closed.append)
    return closed


@pytest.fixture
def app(tmp_path, closed_rooms):
    signaling.cameras.clear()
    signaling.viewers.clear()
    app = create_app({
        'SQLITE_PATH': str(tmp_path / 'test.db'),
        'RECORDINGS_DIR': str(tmp_path / 'recordings'),
        'SUPABASE_JWT_SECRET': TEST_SECRET,
        'LIVEKIT_URL': 'ws://livekit.test:7880',
        'LIVEKIT_API_KEY': 'devkey',
        'LIVEKIT_API_SECRET': LIVEKIT_SECRET,
        'TESTING': True,
    })
    yield app
    signaling.cameras.clear()
    signaling.viewers.clear()


@pytest.fixture
def client(app):
    return app.test_client()


def user_token(user_id, *, email=None, expires_in=3600, secret=TEST_SECRET):
    """A token shaped like the access tokens Supabase Auth issues."""
    return jwt.encode(
        {
            'sub': user_id,
            'email': email or f'{user_id}@example.com',
            'aud': 'authenticated',
            'role': 'authenticated',
            'exp': int(time.time()) + expires_in,
        },
        secret,
        algorithm='HS256',
    )


def as_user(user_id):
    return {'Authorization': f'Bearer {user_token(user_id)}'}


def as_device(token):
    return {'Authorization': f'Device {token}'}


def home_household(client, user_id):
    return client.get('/me', headers=as_user(user_id)).get_json()['households'][0]['id']


def pair_camera(client, user_id, name='Front Door', household_id=None):
    household_id = household_id or home_household(client, user_id)
    code = client.post(f'/households/{household_id}/pairing-codes', headers=as_user(user_id)).get_json()['code']
    return client.post('/devices/pair', json={'code': code, 'name': name}).get_json()


def upload_clip(client, device_token, event_id, data=b'fake mp4 bytes'):
    """Attaches a clip the way the camera does: ask for a signed upload URL,
    PUT the file to it, then report it done. Returns the first response that
    isn't a success, or the final `done` response."""
    resp = client.post(f'/motion-events/{event_id}/clip/upload', headers=as_device(device_token))
    if resp.status_code != 200:
        return resp
    put = client.put(resp.get_json()['url'], data=data, content_type='video/mp4')
    assert put.status_code == 200
    return client.post(f'/motion-events/{event_id}/clip/done', headers=as_device(device_token))
