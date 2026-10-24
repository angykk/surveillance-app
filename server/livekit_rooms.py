import asyncio
from datetime import timedelta

from livekit import api

# Live video goes through a LiveKit SFU, one room per camera (room name =
# device id). This server never touches media: it only hands out access
# tokens once signaling.py has checked household membership, and closes a
# room when its camera is revoked.
#
# Named livekit_rooms rather than livekit so it doesn't shadow the package.

# LiveKit only checks a token when joining; the SDK keeps a connected client
# supplied with refreshed tokens after that, so these can be short-lived.
TOKEN_TTL = timedelta(minutes=10)

_config = {}


def init(url, api_key, api_secret):
    _config.update(url=url, api_key=api_key, api_secret=api_secret)


def _grant(identity, name, room, *, publish):
    token = (
        api.AccessToken(_config['api_key'], _config['api_secret'])
        .with_identity(identity)
        .with_name(name)
        .with_ttl(TOKEN_TTL)
        .with_grants(api.VideoGrants(
            room_join=True,
            room=room,
            can_publish=publish,
            can_subscribe=not publish,
            can_publish_data=False,
        ))
        .to_jwt()
    )
    return {'url': _config['url'], 'token': token}


def camera_grant(device_id, name):
    """Publish-only. A fixed identity per camera means a reconnecting camera
    replaces its own stale participant rather than joining twice."""
    return _grant(f'camera:{device_id}', name, device_id, publish=True)


def viewer_grant(device_id, user_id, sid):
    """Subscribe-only. Includes the socket id so the same user can watch from
    two phones at once (LiveKit kicks a duplicate identity)."""
    return _grant(f'viewer:{user_id}:{sid}', 'viewer', device_id, publish=False)


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
