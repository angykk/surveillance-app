import signaling
from conftest import as_user, pair_camera, user_token


def _connect_viewer(app, user_id):
    return signaling.socketio.test_client(app, auth={'token': user_token(user_id)})


def _connect_camera(app, device_token):
    return signaling.socketio.test_client(app, auth={'device_token': device_token})


def _received(client, event):
    return [m['args'][0] for m in client.get_received() if m['name'] == event]


def _report(camera, level=80, charging=False, thermal='nominal'):
    camera.emit('camera-health', {'battery_level': level, 'battery_charging': charging, 'thermal_state': thermal})


def _roster_health(viewer, device_id):
    roster = _received(viewer, 'cameras-list')[-1]
    return next(c for c in roster if c['id'] == device_id)['health']


def _fire_offline_alert(device_id):
    """Runs a pending offline alert now rather than waiting it out."""
    timer = signaling._offline_timers[device_id]
    timer.cancel()
    timer.function(*timer.args)


def test_health_report_reaches_the_roster_and_outlives_the_connection(app, client):
    cam = pair_camera(client, 'alice')
    alice = _connect_viewer(app, 'alice')
    assert _roster_health(alice, cam['device_id']) is None

    camera = _connect_camera(app, cam['device_token'])
    _report(camera, level=64, charging=True, thermal='fair')
    assert _roster_health(alice, cam['device_id']) == {
        'battery_level': 64, 'battery_charging': True, 'thermal_state': 'fair',
    }

    # An offline camera keeps showing its last report, as does a new viewer.
    camera.disconnect()
    roster = _received(_connect_viewer(app, 'alice'), 'cameras-list')[-1]
    assert roster[0]['online'] is False
    assert roster[0]['health']['battery_level'] == 64


def test_unchanged_health_report_does_not_rebroadcast(app, client):
    cam = pair_camera(client, 'alice')
    camera = _connect_camera(app, cam['device_token'])
    alice = _connect_viewer(app, 'alice')
    _report(camera)
    alice.get_received()

    _report(camera)
    assert _received(alice, 'cameras-list') == []


def test_malformed_health_fields_are_dropped(app, client):
    cam = pair_camera(client, 'alice')
    camera = _connect_camera(app, cam['device_token'])
    alice = _connect_viewer(app, 'alice')
    camera.emit('camera-health', {'battery_level': 140, 'battery_charging': 'yes', 'thermal_state': 'melting'})
    assert _roster_health(alice, cam['device_id']) is None

    camera.emit('camera-health', {'battery_level': True, 'thermal_state': 'serious'})
    assert _roster_health(alice, cam['device_id']) == {
        'battery_level': None, 'battery_charging': None, 'thermal_state': 'serious',
    }


def test_viewers_cannot_report_health(app, client):
    cam = pair_camera(client, 'alice')
    alice = _connect_viewer(app, 'alice')
    alice.get_received()
    _report(alice, level=5)
    assert _received(alice, 'camera-alert') == []
    roster = _received(_connect_viewer(app, 'alice'), 'cameras-list')[-1]
    assert [(c['id'], c['health']) for c in roster] == [(cam['device_id'], None)]


def test_low_battery_alerts_once_per_drop_and_only_the_household(app, client):
    cam = pair_camera(client, 'alice', name='Porch')
    camera = _connect_camera(app, cam['device_token'])
    alice = _connect_viewer(app, 'alice')
    bob = _connect_viewer(app, 'bob')
    _report(camera, level=21)
    assert _received(alice, 'camera-alert') == []

    _report(camera, level=20)
    alerts = _received(alice, 'camera-alert')
    assert [(a['kind'], a['camera_id'], a['camera_name']) for a in alerts] == [
        ('battery-low', cam['device_id'], 'Porch'),
    ]
    assert _received(bob, 'camera-alert') == []

    # Still low: no repeat, even across a reconnect.
    _report(camera, level=19)
    camera.disconnect()
    camera = _connect_camera(app, cam['device_token'])
    _report(camera, level=18)
    assert _received(alice, 'camera-alert') == []

    # Plugging in clears it; unplugging while still low raises it again.
    _report(camera, level=18, charging=True)
    assert _received(alice, 'camera-alert') == []
    _report(camera, level=18, charging=False)
    assert [a['kind'] for a in _received(alice, 'camera-alert')] == ['battery-low']


def test_running_hot_alerts_on_the_change(app, client):
    cam = pair_camera(client, 'alice')
    camera = _connect_camera(app, cam['device_token'])
    alice = _connect_viewer(app, 'alice')
    _report(camera, thermal='fair')
    _report(camera, thermal='serious')
    _report(camera, thermal='critical')
    assert [a['kind'] for a in _received(alice, 'camera-alert')] == ['hot']


def test_camera_offline_too_long_alerts_the_household(app, client):
    cam = pair_camera(client, 'alice', name='Porch')
    camera = _connect_camera(app, cam['device_token'])
    alice = _connect_viewer(app, 'alice')
    camera.disconnect()
    alice.get_received()

    _fire_offline_alert(cam['device_id'])
    alerts = _received(alice, 'camera-alert')
    assert [(a['kind'], a['camera_name']) for a in alerts] == [('offline', 'Porch')]


def test_camera_back_in_time_does_not_alert(app, client):
    cam = pair_camera(client, 'alice')
    camera = _connect_camera(app, cam['device_token'])
    camera.disconnect()
    timer = signaling._offline_timers[cam['device_id']]

    _connect_camera(app, cam['device_token'])
    assert cam['device_id'] not in signaling._offline_timers
    assert not timer.is_alive() or timer.finished.is_set()


def test_camera_stopped_on_purpose_does_not_alert(app, client):
    cam = pair_camera(client, 'alice')
    camera = _connect_camera(app, cam['device_token'])
    assert camera.emit('camera-stopping', callback=True) is True
    camera.disconnect()
    assert cam['device_id'] not in signaling._offline_timers


def test_camera_removed_while_offline_does_not_alert(app, client):
    cam = pair_camera(client, 'alice')
    camera = _connect_camera(app, cam['device_token'])
    alice = _connect_viewer(app, 'alice')
    camera.disconnect()
    timer = signaling._offline_timers[cam['device_id']]

    assert client.delete(f"/devices/{cam['device_id']}", headers=as_user('alice')).status_code == 204
    alice.get_received()
    # Even if the timer had already fired as the camera was removed.
    timer.function(*timer.args)
    assert _received(alice, 'camera-alert') == []
