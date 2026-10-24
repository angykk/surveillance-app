import os
import tempfile

from flask import Blueprint, abort, current_app, request, send_from_directory, url_for
from itsdangerous import BadSignature, URLSafeTimedSerializer
from storage3.exceptions import StorageApiError
from storage3.types import CreateSignedUploadUrlOptions

import db

# Where motion clips live. The camera uploads each clip straight to storage
# with a signed URL, and viewers play it back from another signed URL, so
# video bytes never pass through this server (with Supabase Storage).
#
# Keys look like `households/<hid>/devices/<did>/<event id>.mp4`, all
# server-issued ids, so they're always safe as paths.
#
# Two backends behind the same four calls:
# - SupabaseStorage: a private bucket in the Supabase project (production).
# - LocalStorage: files under RECORDINGS_DIR, with this server handing out
#   and serving the signed URLs itself (local SQLite testing and pytest).

# Long enough for a viewer to watch and scrub one clip.
PLAYBACK_URL_TTL_S = 3600


def clip_key(event):
    return f"households/{event['household_id']}/devices/{event['device_id']}/{event['id']}.mp4"


class SupabaseStorage:
    def __init__(self, client, bucket):
        self._bucket = client.storage.from_(bucket)

    def upload_url(self, key):
        # Upsert, so a camera retrying after a failed `done` call (the upload
        # itself having gone through) can upload again.
        signed = self._bucket.create_signed_upload_url(key, CreateSignedUploadUrlOptions(upsert='true'))
        return signed['signed_url']

    def size(self, key):
        """The stored object's size in bytes, or None if it isn't there."""
        try:
            info = self._bucket.info(key)
        except StorageApiError as exc:
            # Storage answers a missing object with a 400 or 404; anything
            # else is a real failure.
            if str(exc.status) in ('400', '404'):
                return None
            raise
        return info.get('size')

    def playback_url(self, key):
        return self._bucket.create_signed_url(key, PLAYBACK_URL_TTL_S)['signedURL']

    def delete(self, keys):
        if keys:
            self._bucket.remove(list(keys))


class LocalStorage:
    def __init__(self, root, secret):
        self._root = root
        self._signer = URLSafeTimedSerializer(secret, salt='local-clips')

    def _path(self, key):
        return os.path.join(self._root, *key.split('/'))

    def _url(self, key, op):
        token = self._signer.dumps({'key': key, 'op': op})
        # The request's own host, i.e. whatever address the phone used to
        # reach this server, so the URL works from the phone too.
        return url_for('clip_storage.local_clip', key=key, t=token, _external=True)

    def check(self, key, op, token, max_age):
        try:
            data = self._signer.loads(token, max_age=max_age)
        except BadSignature:
            return False
        return data == {'key': key, 'op': op}

    def upload_url(self, key):
        return self._url(key, 'put')

    def size(self, key):
        path = self._path(key)
        return os.path.getsize(path) if os.path.isfile(path) else None

    def playback_url(self, key):
        return self._url(key, 'get')

    def delete(self, keys):
        for key in keys:
            try:
                os.remove(self._path(key))
            except FileNotFoundError:
                pass

    def save(self, key, stream):
        # Written to a temp file and renamed into place, so an upload that
        # drops halfway never leaves a truncated clip under the key for a
        # later `done` to record.
        path = self._path(key)
        directory = os.path.dirname(path)
        os.makedirs(directory, exist_ok=True)
        fd, tmp_path = tempfile.mkstemp(dir=directory, suffix='.part')
        try:
            with os.fdopen(fd, 'wb') as f:
                while chunk := stream.read(1024 * 1024):
                    f.write(chunk)
            os.replace(tmp_path, path)
        except BaseException:
            os.remove(tmp_path)
            raise

    def send(self, key):
        directory, filename = os.path.split(self._path(key))
        # Handles Range requests, which is what lets video_player scrub.
        return send_from_directory(directory, filename)


def get():
    return current_app.extensions['clip_storage']


bp = Blueprint('clip_storage', __name__)


@bp.route('/local-clips/<path:key>', methods=['GET', 'PUT'])
def local_clip(key):
    """The signed upload and playback URLs LocalStorage hands out. The token
    in the URL is the only credential, like a Supabase signed URL."""
    storage = get()
    if not isinstance(storage, LocalStorage):
        abort(404)
    op = 'put' if request.method == 'PUT' else 'get'
    max_age = 2 * 3600 if op == 'put' else PLAYBACK_URL_TTL_S
    if not storage.check(key, op, request.args.get('t', ''), max_age):
        abort(403)
    if op == 'put':
        # An upload URL outlives its event if retention (or a deletion)
        # removes the event meanwhile; storing the file then would leave an
        # object nothing tracks or cleans up.
        if db.first(db.table('motion_events').select('id').eq('clip_key', key).limit(1).execute()) is None:
            abort(404)
        storage.save(key, request.stream)
        return '', 200
    if storage.size(key) is None:
        abort(404)
    return storage.send(key)
