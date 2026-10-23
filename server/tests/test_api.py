import time

from conftest import as_device, as_user, home_household, pair_camera, upload_clip, user_token


def test_requests_without_valid_token_are_rejected(client):
    assert client.get('/me').status_code == 401
    assert client.get('/me', headers={'Authorization': 'Bearer garbage'}).status_code == 401
    expired = user_token('alice', expires_in=-10)
    assert client.get('/me', headers={'Authorization': f'Bearer {expired}'}).status_code == 401
    forged = user_token('alice', secret='some-other-secret-that-is-32-bytes!!')
    assert client.get('/me', headers={'Authorization': f'Bearer {forged}'}).status_code == 401


def test_first_sign_in_provisions_a_home_household(client):
    me = client.get('/me', headers=as_user('alice')).get_json()
    assert me['id'] == 'alice'
    assert [(h['name'], h['role']) for h in me['households']] == [('Home', 'owner')]
    # Idempotent on later requests.
    assert len(client.get('/me', headers=as_user('alice')).get_json()['households']) == 1


def test_pairing_code_is_single_use(client):
    household_id = home_household(client, 'alice')
    code = client.post(f'/households/{household_id}/pairing-codes', headers=as_user('alice')).get_json()['code']

    first = client.post('/devices/pair', json={'code': code, 'name': 'Porch'})
    assert first.status_code == 201
    assert first.get_json()['household_id'] == household_id
    assert client.post('/devices/pair', json={'code': code, 'name': 'Sneaky'}).status_code == 400


def test_expired_pairing_code_is_rejected(client, monkeypatch):
    household_id = home_household(client, 'alice')
    code = client.post(f'/households/{household_id}/pairing-codes', headers=as_user('alice')).get_json()['code']
    real_time = time.time
    monkeypatch.setattr(time, 'time', lambda: real_time() + 11 * 60)
    assert client.post('/devices/pair', json={'code': code, 'name': 'Porch'}).status_code == 400


def test_cannot_mint_pairing_codes_for_someone_elses_household(client):
    bobs_household = home_household(client, 'bob')
    resp = client.post(f'/households/{bobs_household}/pairing-codes', headers=as_user('alice'))
    assert resp.status_code == 404


def test_recordings_are_scoped_to_household(client):
    alice_cam = pair_camera(client, 'alice')
    bob_cam = pair_camera(client, 'bob', name='Garage')
    alice_clip = upload_clip(client, alice_cam['device_token']).get_json()['id']
    upload_clip(client, bob_cam['device_token'])

    # Each user only sees their own household's clips.
    alice_list = client.get('/recordings', headers=as_user('alice')).get_json()
    assert [r['id'] for r in alice_list] == [alice_clip]
    assert alice_list[0]['camera_name'] == 'Front Door'

    # Bob can't list, fetch, or delete Alice's camera's clips.
    assert client.get(f"/recordings?camera_id={alice_cam['device_id']}", headers=as_user('bob')).status_code == 404
    assert client.get(f'/recordings/{alice_clip}/file', headers=as_user('bob')).status_code == 404
    assert client.delete(f'/recordings/{alice_clip}', headers=as_user('bob')).status_code == 404

    # Alice can.
    file_resp = client.get(f'/recordings/{alice_clip}/file', headers=as_user('alice'))
    assert file_resp.status_code == 200 and file_resp.data == b'fake mp4 bytes'
    assert client.delete(f'/recordings/{alice_clip}', headers=as_user('alice')).status_code == 204
    assert client.get('/recordings', headers=as_user('alice')).get_json() == []


def test_upload_requires_device_token(client):
    assert upload_clip(client, 'not-a-real-token').status_code == 401
    # A user token isn't a device credential.
    resp = client.post('/recordings', headers=as_user('alice'))
    assert resp.status_code == 401


def test_revoked_device_token_stops_working(client):
    cam = pair_camera(client, 'alice')
    assert upload_clip(client, cam['device_token']).status_code == 201

    assert client.delete(f"/devices/{cam['device_id']}", headers=as_user('bob')).status_code == 404
    assert client.delete(f"/devices/{cam['device_id']}", headers=as_user('alice')).status_code == 204
    assert upload_clip(client, cam['device_token']).status_code == 401
    # Its earlier clips stay with the household.
    assert len(client.get('/recordings', headers=as_user('alice')).get_json()) == 1


def test_device_can_rename_itself(client):
    cam = pair_camera(client, 'alice')
    resp = client.patch('/devices/me', headers=as_device(cam['device_token']), json={'name': 'Back Yard'})
    assert resp.status_code == 200
    upload_clip(client, cam['device_token'])
    assert client.get('/recordings', headers=as_user('alice')).get_json()[0]['camera_name'] == 'Back Yard'


def test_invalid_names_are_rejected(client):
    household_id = home_household(client, 'alice')
    code = client.post(f'/households/{household_id}/pairing-codes', headers=as_user('alice')).get_json()['code']
    assert client.post('/devices/pair', json={'code': code, 'name': '   '}).status_code == 400
    assert client.post('/devices/pair', json={'code': code, 'name': 'x' * 65}).status_code == 400


def test_malformed_ids_are_not_found(client):
    # Ids are uuid columns in Postgres, which errors on anything else; these
    # must come back as a plain 404 rather than a server error.
    assert client.get('/recordings?camera_id=nope', headers=as_user('alice')).status_code == 404
    assert client.get('/recordings/nope/file', headers=as_user('alice')).status_code == 404
    assert client.delete('/devices/nope', headers=as_user('alice')).status_code == 404
    assert client.post('/households/nope/pairing-codes', headers=as_user('alice')).status_code == 404
