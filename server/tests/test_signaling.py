import jwt

import signaling
from conftest import LIVEKIT_SECRET, as_user, pair_camera, user_token


def _connect_viewer(app, user_id):
    return signaling.socketio.test_client(app, auth={'token': user_token(user_id)})


def _connect_camera(app, device_token):
    return signaling.socketio.test_client(app, auth={'device_token': device_token})


def _last(client, event):
    matches = [m for m in client.get_received() if m['name'] == event]
    return matches[-1]['args'][0] if matches and matches[-1]['args'] else (matches[-1] if matches else None)


def _names(client):
    return [m['name'] for m in client.get_received()]


def _video_grant(grant):
    assert grant['url'] == 'ws://livekit.test:7880'
    return jwt.decode(grant['token'], LIVEKIT_SECRET, algorithms=['HS256'])['video']


def _watch(viewer, device_id):
    return viewer.emit('watch-camera', {'camera_id': device_id}, callback=True)


def test_unauthenticated_sockets_are_refused(app):
    assert not signaling.socketio.test_client(app).is_connected()
    assert not signaling.socketio.test_client(app, auth={'token': 'garbage'}).is_connected()
    assert not _connect_camera(app, 'garbage').is_connected()


def test_viewer_roster_only_contains_own_households_cameras(app, client):
    alice_cam = pair_camera(client, 'alice')
    bob_cam = pair_camera(client, 'bob', name='Garage')

    _connect_camera(app, alice_cam['device_token'])
    _connect_camera(app, bob_cam['device_token'])
    alice = _connect_viewer(app, 'alice')

    roster = _last(alice, 'cameras-list')
    assert [(c['id'], c['online']) for c in roster] == [(alice_cam['device_id'], True)]


def test_viewer_cannot_watch_another_households_camera(app, client):
    bob_cam = pair_camera(client, 'bob', name='Garage')
    bob_camera = _connect_camera(app, bob_cam['device_token'])
    bob_camera.get_received()

    mallory = _connect_viewer(app, 'mallory')
    mallory.get_received()
    assert not _watch(mallory, bob_cam['device_id'])
    assert _names(mallory) == ['peer-left']
    # The camera was never asked to start streaming.
    assert _names(bob_camera) == []


def test_watching_hands_out_scoped_livekit_grants(app, client):
    cam = pair_camera(client, 'alice')
    camera = _connect_camera(app, cam['device_token'])
    alice = _connect_viewer(app, 'alice')
    camera.get_received()

    viewer_grant = _video_grant(_watch(alice, cam['device_id']))
    assert viewer_grant['room'] == cam['device_id']
    assert viewer_grant['canSubscribe'] is True
    assert viewer_grant['canPublish'] is False
    assert viewer_grant['canPublishData'] is False

    camera_grant = _video_grant(_last(camera, 'stream-start'))
    assert camera_grant['room'] == cam['device_id']
    assert camera_grant['canPublish'] is True
    assert camera_grant['canSubscribe'] is False


def test_camera_streams_until_its_last_viewer_leaves(app, client):
    cam = pair_camera(client, 'alice')
    camera = _connect_camera(app, cam['device_token'])
    phone_a = _connect_viewer(app, 'alice')
    phone_b = _connect_viewer(app, 'alice')
    camera.get_received()

    grant_a = _watch(phone_a, cam['device_id'])
    grant_b = _watch(phone_b, cam['device_id'])
    assert grant_a['token'] != grant_b['token']
    # Only the first watcher starts the stream.
    assert _names(camera) == ['stream-start']

    phone_a.emit('stop-watching')
    assert _names(camera) == []
    phone_b.disconnect()
    assert _names(camera) == ['stream-stop']

    # Watching again restarts it.
    _watch(phone_a, cam['device_id'])
    assert _names(camera) == ['stream-start']


def test_switching_cameras_releases_the_previous_one(app, client):
    front = pair_camera(client, 'alice')
    garage = pair_camera(client, 'alice', name='Garage')
    front_camera = _connect_camera(app, front['device_token'])
    garage_camera = _connect_camera(app, garage['device_token'])
    alice = _connect_viewer(app, 'alice')

    _watch(alice, front['device_id'])
    front_camera.get_received()
    garage_camera.get_received()

    _watch(alice, garage['device_id'])
    assert _names(front_camera) == ['stream-stop']
    assert _names(garage_camera) == ['stream-start']


def test_revoking_a_device_disconnects_it_and_blocks_reconnect(app, client, closed_rooms):
    cam = pair_camera(client, 'alice')
    camera = _connect_camera(app, cam['device_token'])
    alice = _connect_viewer(app, 'alice')
    alice.get_received()

    client.delete(f"/devices/{cam['device_id']}", headers=as_user('alice'))
    assert not camera.is_connected()
    assert _last(alice, 'cameras-list') == []
    assert not _connect_camera(app, cam['device_token']).is_connected()
    # Its LiveKit room is closed too, in case it ignores the disconnect.
    assert closed_rooms == [cam['device_id']]


def test_new_pairing_shows_up_in_live_roster(app, client):
    alice = _connect_viewer(app, 'alice')
    alice.get_received()
    cam = pair_camera(client, 'alice')
    assert [(c['id'], c['name'], c['online']) for c in _last(alice, 'cameras-list')] == [
        (cam['device_id'], 'Front Door', False),
    ]


def test_motion_reaches_only_same_household_viewers(app, client):
    cam = pair_camera(client, 'alice')
    camera = _connect_camera(app, cam['device_token'])
    alice = _connect_viewer(app, 'alice')
    bob = _connect_viewer(app, 'bob')
    alice.get_received()
    bob.get_received()

    camera.emit('motion-start')
    started = _last(alice, 'motion')
    assert started['camera_id'] == cam['device_id'] and started['ended_at'] is None
    # A repeated start while motion is ongoing doesn't open a second event.
    camera.emit('motion-start')
    assert _last(alice, 'motion') is None

    camera.emit('motion-end')
    ended = _last(alice, 'motion')
    assert ended['id'] == started['id'] and ended['ended_at'] is not None
    assert _last(bob, 'motion') is None


def test_viewers_cannot_report_motion(app, client):
    cam = pair_camera(client, 'alice')
    alice = _connect_viewer(app, 'alice')
    alice.get_received()
    alice.emit('motion-start')
    assert _last(alice, 'motion') is None
    assert client.get(f"/devices/{cam['device_id']}/motion-events", headers=as_user('alice')).get_json() == []


def test_camera_disconnect_closes_open_motion_event(app, client):
    cam = pair_camera(client, 'alice')
    camera = _connect_camera(app, cam['device_token'])
    alice = _connect_viewer(app, 'alice')
    camera.emit('motion-start')
    alice.get_received()

    camera.disconnect()
    assert _last(alice, 'motion')['ended_at'] is not None
    [event] = client.get(f"/devices/{cam['device_id']}/motion-events", headers=as_user('alice')).get_json()
    assert event['ended_at'] is not None
