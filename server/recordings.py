import os

from flask import Blueprint, abort, current_app, g, jsonify, request, send_from_directory

import auth
import db

bp = Blueprint('recordings', __name__)

# Motion clips are uploaded here by camera devices (see `_stopMotionRecording`
# in the mobile app) and served back out to members of the camera's
# household. Metadata lives in the database; clip files sit on disk under
# RECORDINGS_DIR, one subfolder per device id. Device ids are server-issued,
# so they're always safe to use as directory names.


def _recordings_dir():
    return current_app.config['RECORDINGS_DIR']


# Each recording comes back with its camera's name embedded via the
# recordings.device_id foreign key.
_RECORDING_COLUMNS = 'id, device_id, household_id, filename, created_at, size_bytes, devices(name)'


def _serialize(row):
    return {
        'id': row['id'],
        'camera_id': row['device_id'],
        'camera_name': row['devices']['name'],
        'created_at': row['created_at'],
        'size_bytes': row['size_bytes'],
    }


def _recording_or_404(recording_id):
    if not db.is_id(recording_id):
        abort(404)
    row = db.first(db.table('recordings').select(_RECORDING_COLUMNS).eq('id', recording_id).limit(1).execute())
    if row is None:
        abort(404)
    return row


@bp.route('/recordings', methods=['POST'])
@auth.require_device
def upload_recording():
    file = request.files.get('file')
    if file is None:
        abort(400)

    device = g.device
    recording_id = db.new_id()
    device_dir = os.path.join(_recordings_dir(), device['id'])
    os.makedirs(device_dir, exist_ok=True)
    filename = f'{recording_id}.mp4'
    path = os.path.join(device_dir, filename)
    file.save(path)
    size_bytes = os.path.getsize(path)

    db.table('recordings').insert({
        'id': recording_id,
        'device_id': device['id'],
        'household_id': device['household_id'],
        'filename': filename,
        'created_at': db.now(),
        'size_bytes': size_bytes,
    }).execute()

    print(f"Stored recording {recording_id} from camera '{device['name']}' ({device['id']}), {size_bytes} bytes")
    return jsonify({'id': recording_id}), 201


@bp.route('/recordings', methods=['GET'])
@auth.require_user
def list_recordings():
    """Recordings for one camera (`?camera_id=`), or for every household the
    user belongs to when no camera is given."""
    query = db.table('recordings').select(_RECORDING_COLUMNS)
    camera_id = request.args.get('camera_id')
    if camera_id:
        if not db.is_id(camera_id):
            abort(404)
        device = db.first(db.table('devices').select('household_id').eq('id', camera_id).limit(1).execute())
        if device is None:
            abort(404)
        auth.require_member(device['household_id'])
        query = query.eq('device_id', camera_id)
    else:
        household_ids = auth.household_ids_of(g.user_id)
        if not household_ids:
            return jsonify([])
        query = query.in_('household_id', list(household_ids))

    rows = query.order('created_at', desc=True).execute().data
    return jsonify([_serialize(row) for row in rows])


@bp.route('/recordings/<recording_id>/file')
@auth.require_user
def recording_file(recording_id):
    row = _recording_or_404(recording_id)
    auth.require_member(row['household_id'])
    # send_from_directory handles Range requests, which is what lets
    # video_player seek/scrub instead of only playing from the start.
    return send_from_directory(os.path.join(_recordings_dir(), row['device_id']), row['filename'])


@bp.route('/recordings/<recording_id>', methods=['DELETE'])
@auth.require_user
def delete_recording(recording_id):
    row = _recording_or_404(recording_id)
    auth.require_member(row['household_id'], roles=db.MANAGER_ROLES)
    db.table('recordings').delete().eq('id', recording_id).execute()

    path = os.path.join(_recordings_dir(), row['device_id'], row['filename'])
    if os.path.exists(path):
        os.remove(path)
    return '', 204
