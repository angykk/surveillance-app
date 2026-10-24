import os
import time

import db
import retention
import signaling
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


def _motion_events(client, user_id, device_id):
    return client.get(f'/devices/{device_id}/motion-events', headers=as_user(user_id))


def test_motion_events_are_scoped_to_household(app, client):
    alice_cam = pair_camera(client, 'alice')
    camera = signaling.socketio.test_client(app, auth={'device_token': alice_cam['device_token']})
    camera.emit('motion-start')
    camera.emit('motion-end')
    camera.emit('motion-start')

    resp = _motion_events(client, 'alice', alice_cam['device_id'])
    assert resp.status_code == 200
    events = resp.get_json()
    # Newest first; the second stretch of motion is still ongoing.
    assert [e['ended_at'] is None for e in events] == [True, False]
    assert all(e['camera_id'] == alice_cam['device_id'] for e in events)

    assert _motion_events(client, 'bob', alice_cam['device_id']).status_code == 404


def _motion_event(app, camera_token):
    camera = signaling.socketio.test_client(app, auth={'device_token': camera_token})
    event_id = camera.emit('motion-start', callback=True)['id']
    camera.emit('motion-end')
    return event_id


def test_clips_attach_to_their_own_event_and_stay_in_household(app, client):
    alice_cam = pair_camera(client, 'alice')
    bob_cam = pair_camera(client, 'bob', name='Garage')
    event_id = _motion_event(app, alice_cam['device_token'])
    clip_url = f'/motion-events/{event_id}/clip-url'

    # No clip yet.
    assert client.get(clip_url, headers=as_user('alice')).status_code == 404
    # Only the camera that saw the motion can attach its clip, and only once.
    assert upload_clip(client, bob_cam['device_token'], event_id).status_code == 404
    assert client.post(f'/motion-events/{event_id}/clip/upload', headers=as_user('alice')).status_code == 401
    assert upload_clip(client, alice_cam['device_token'], event_id).status_code == 204
    assert upload_clip(client, alice_cam['device_token'], event_id).status_code == 409

    [event] = _motion_events(client, 'alice', alice_cam['device_id']).get_json()
    assert event['has_clip'] is True
    resp = client.get(clip_url, headers=as_user('alice'))
    assert resp.status_code == 200
    # The player streams from the signed URL itself, with no auth headers.
    assert client.get(resp.get_json()['url']).data == b'fake mp4 bytes'
    assert client.get(clip_url, headers=as_user('bob')).status_code == 404


def test_clip_done_needs_the_upload_and_can_be_retried(app, client):
    cam = pair_camera(client, 'alice')
    event_id = _motion_event(app, cam['device_token'])
    headers = as_device(cam['device_token'])

    first_url = client.post(f'/motion-events/{event_id}/clip/upload', headers=headers).get_json()['url']
    # Nothing was uploaded, so the event can't be marked done.
    assert client.post(f'/motion-events/{event_id}/clip/done', headers=headers).status_code == 400
    # A retry gets a fresh URL for the same object, and the upload completes.
    assert upload_clip(client, cam['device_token'], event_id).status_code == 204
    assert first_url.split('?')[0] == client.get(
        f'/motion-events/{event_id}/clip-url', headers=as_user('alice')
    ).get_json()['url'].split('?')[0]


def test_signed_clip_urls_only_allow_their_own_object_and_operation(app, client):
    cam = pair_camera(client, 'alice')
    event_id = _motion_event(app, cam['device_token'])
    upload_url = client.post(f'/motion-events/{event_id}/clip/upload', headers=as_device(cam['device_token'])).get_json()['url']
    path, token = upload_url.split('?t=')

    # An upload URL can't be used to download, nor for another key.
    assert client.get(upload_url).status_code == 403
    assert client.put(path.replace(event_id, db.new_id()) + '?t=' + token, data=b'x').status_code == 403
    assert client.put(path + '?t=forged', data=b'x').status_code == 403


def _stored_keys(app):
    root = app.config['RECORDINGS_DIR']
    return sorted(
        os.path.relpath(os.path.join(dirpath, name), root)
        for dirpath, _, names in os.walk(root)
        for name in names
    )


def test_retention_deletes_old_events_and_their_clips(app, client):
    cam = pair_camera(client, 'alice')
    old_event = _motion_event(app, cam['device_token'])
    new_event = _motion_event(app, cam['device_token'])
    for event_id in (old_event, new_event):
        assert upload_clip(client, cam['device_token'], event_id).status_code == 204
    db.table('motion_events').update({'started_at': db.now() - 31 * 86400}).eq('id', old_event).execute()

    retention.run_once(30, app.extensions['clip_storage'])

    events = _motion_events(client, 'alice', cam['device_id']).get_json()
    assert [e['id'] for e in events] == [new_event]
    assert [os.path.basename(k) for k in _stored_keys(app)] == [f'{new_event}.mp4']
    assert db.table('clip_deletions').select('clip_key').execute().data == []


def test_cascaded_deletes_still_clean_up_clips(app, client):
    cam = pair_camera(client, 'alice')
    event_id = _motion_event(app, cam['device_token'])
    assert upload_clip(client, cam['device_token'], event_id).status_code == 204
    # E.g. the user was deleted in Supabase Auth, which cascades without the
    # server hearing about it.
    db.table('users').delete().eq('id', 'alice').execute()
    assert _stored_keys(app) != []

    retention.run_once(0, app.extensions['clip_storage'])
    assert _stored_keys(app) == []


def test_revoked_device_token_stops_working(client):
    cam = pair_camera(client, 'alice')
    rename = lambda: client.patch('/devices/me', headers=as_device(cam['device_token']), json={'name': 'Porch'})
    assert rename().status_code == 200

    assert client.delete(f"/devices/{cam['device_id']}", headers=as_user('bob')).status_code == 404
    assert client.delete(f"/devices/{cam['device_id']}", headers=as_user('alice')).status_code == 204
    assert rename().status_code == 401


def test_device_endpoints_require_device_token(client):
    assert client.patch('/devices/me', headers=as_device('not-a-real-token'), json={'name': 'x'}).status_code == 401
    # A user token isn't a device credential.
    assert client.patch('/devices/me', headers=as_user('alice'), json={'name': 'x'}).status_code == 401


def test_device_can_rename_itself(client):
    cam = pair_camera(client, 'alice')
    resp = client.patch('/devices/me', headers=as_device(cam['device_token']), json={'name': 'Back Yard'})
    assert resp.status_code == 200
    assert resp.get_json()['name'] == 'Back Yard'


def test_invalid_names_are_rejected(client):
    household_id = home_household(client, 'alice')
    code = client.post(f'/households/{household_id}/pairing-codes', headers=as_user('alice')).get_json()['code']
    assert client.post('/devices/pair', json={'code': code, 'name': '   '}).status_code == 400
    assert client.post('/devices/pair', json={'code': code, 'name': 'x' * 65}).status_code == 400


def test_malformed_ids_are_not_found(client):
    # Ids are uuid columns in Postgres, which errors on anything else; these
    # must come back as a plain 404 rather than a server error.
    assert client.get('/devices/nope/motion-events', headers=as_user('alice')).status_code == 404
    assert client.get('/motion-events/nope/clip-url', headers=as_user('alice')).status_code == 404
    assert client.delete('/devices/nope', headers=as_user('alice')).status_code == 404
    assert client.post('/households/nope/pairing-codes', headers=as_user('alice')).status_code == 404
