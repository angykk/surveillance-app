import asyncio
import secrets
from datetime import timedelta

from livekit import api

# Live video goes through a LiveKit SFU, one room per camera (room name =
# device id). This server never touches media: it only hands out access
# tokens once signaling.py has checked household membership, and closes a
# room when its camera is revoked. Viewers may publish a mic too, to talk
# through the camera; they only let the camera subscribe to it (see the
# viewer screen), so household members don't hear each other.
#
# Named livekit_rooms rather than livekit so it doesn't shadow the package.

# LiveKit only checks a token when joining; the SDK keeps a connected client
# supplied with refreshed tokens after that, so these can be short-lived.
TOKEN_TTL = timedelta(minutes=10)

_config = {}


def init(url, api_key, api_secret):
    _config.update(url=url, api_key=api_key, api_secret=api_secret)


def _grant(identity, name, room, *, sources):
    token = (
        api.AccessToken(_config['api_key'], _config['api_secret'])
        .with_identity(identity)
        .with_name(name)
        .with_ttl(TOKEN_TTL)
        .with_grants(api.VideoGrants(
            room_join=True,
            room=room,
            can_publish=True,
            can_publish_sources=sources,
            can_subscribe=True,
            can_publish_data=False,
        ))
        .to_jwt()
    )
    return {'url': _config['url'], 'token': token}


def camera_identity(device_id):
    """A fixed identity per camera means a reconnecting camera replaces its
    own stale participant rather than joining twice. Viewers rely on this
    format to let only the camera hear them talk."""
    return f'camera:{device_id}'


def camera_grant(device_id, name):
    """Publishes the camera and mic, and subscribes so the camera can play
    back viewers talking through it."""
    return _grant(camera_identity(device_id), name, device_id, sources=['camera', 'microphone'])


def viewer_grant(device_id, user_id, sid):
    """Subscribes to the camera, and may publish a mic only, for talking
    through it. LiveKit kicks a duplicate identity, so each grant gets its
    own: the socket id lets the same user watch from two phones at once, and
    the random suffix keeps a viewer that backs out and straight back in
    (same socket) from colliding with its own session that's still leaving."""
    return _grant(f'viewer:{user_id}:{sid}:{secrets.token_hex(4)}', 'viewer', device_id, sources=['microphone'])


def close_room(device_id):
    """Kicks everyone out of a camera's room, e.g. after it's revoked, even a
    client that ignores the socket telling it to leave. Best-effort: the
    room may not exist (nobody was watching) or LiveKit may be unreachable."""
    async def _delete():
        # The Twirp API is plain HTTP on the same port as the websocket URL.
        http_url = _config['url'].replace('ws://', 'http://', 1).replace('wss://', 'https://', 1)
        lkapi = api.LiveKitAPI(http_url, _config['api_key'], _config['api_secret'])
        try:
            await lkapi.room.delete_room(api.DeleteRoomRequest(room=device_id))
        finally:
            await lkapi.aclose()

    try:
        # The server runs Flask-SocketIO in threading mode, so there's no
        # event loop to schedule this on.
        asyncio.run(_delete())
    except Exception as e:
        print(f"Couldn't close LiveKit room {device_id}: {e}")
