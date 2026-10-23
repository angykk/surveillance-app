import signaling
from conftest import as_user, pair_camera, user_token


def _connect_viewer(app, user_id):
    return signaling.socketio.test_client(app, auth={'token': user_token(user_id)})


def _connect_camera(app, device_token):
    return signaling.socketio.test_client(app, auth={'device_token': device_token})


def _last(client, event):
    matches = [m for m in client.get_received() if m['name'] == event]
    return matches[-1]['args'][0] if matches and matches[-1]['args'] else (matches[-1] if matches else None)


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
    mallory.emit('watch-camera', {'camera_id': bob_cam['device_id']})
    assert any(m['name'] == 'peer-left' for m in mallory.get_received())
    # The camera was never asked to start streaming, and relayed signaling
    # from the outsider goes nowhere.
    mallory.emit('offer', {'sdp': 'x', 'type': 'offer'})
    assert [m['name'] for m in bob_camera.get_received()] == []


def test_member_can_watch_and_relay(app, client):
    cam = pair_camera(client, 'alice')
    camera = _connect_camera(app, cam['device_token'])
    alice = _connect_viewer(app, 'alice')
    camera.get_received()
    alice.get_received()

    alice.emit('watch-camera', {'camera_id': cam['device_id']})
    assert [m['name'] for m in camera.get_received()] == ['peer-joined']

    camera.emit('offer', {'sdp': 'v=0', 'type': 'offer'})
    assert _last(alice, 'offer') == {'sdp': 'v=0', 'type': 'offer'}
    alice.emit('answer', {'sdp': 'v=0', 'type': 'answer'})
    assert _last(camera, 'answer') == {'sdp': 'v=0', 'type': 'answer'}


def test_revoking_a_device_disconnects_it_and_blocks_reconnect(app, client):
    cam = pair_camera(client, 'alice')
    camera = _connect_camera(app, cam['device_token'])
    alice = _connect_viewer(app, 'alice')
    alice.get_received()

    client.delete(f"/devices/{cam['device_id']}", headers=as_user('alice'))
    assert not camera.is_connected()
    assert _last(alice, 'cameras-list') == []
    assert not _connect_camera(app, cam['device_token']).is_connected()


def test_new_pairing_shows_up_in_live_roster(app, client):
    alice = _connect_viewer(app, 'alice')
    alice.get_received()
    cam = pair_camera(client, 'alice')
    assert [(c['id'], c['name'], c['online']) for c in _last(alice, 'cameras-list')] == [
        (cam['device_id'], 'Front Door', False),
    ]
