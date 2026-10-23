import io
import time

import jwt
import pytest

import signaling
from web_rtc import create_app

TEST_SECRET = 'test-secret-at-least-32-bytes-long!!'


@pytest.fixture
def app(tmp_path):
    signaling.cameras.clear()
    signaling.viewers.clear()
    app = create_app({
        'SQLITE_PATH': str(tmp_path / 'test.db'),
        'RECORDINGS_DIR': str(tmp_path / 'recordings'),
        'SUPABASE_JWT_SECRET': TEST_SECRET,
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
    return client.post(
        f'/motion-events/{event_id}/clip',
        headers=as_device(device_token),
        data={'file': (io.BytesIO(data), 'clip.mp4')},
        content_type='multipart/form-data',
    )
