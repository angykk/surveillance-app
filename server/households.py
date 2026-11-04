import secrets

from flask import Blueprint, abort, g, jsonify, request

import auth
import db
import signaling

bp = Blueprint('households', __name__)

PAIRING_CODE_TTL_SECONDS = 10 * 60

# Unambiguous characters only (no 0/O, 1/I/L), since the code can also be
# typed in by hand when a camera can't scan the QR.
_PAIRING_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
_PAIRING_CODE_LENGTH = 8


def _new_pairing_code():
    return ''.join(secrets.choice(_PAIRING_ALPHABET) for _ in range(_PAIRING_CODE_LENGTH))


def _clean_name(value, *, max_length=64):
    name = (value or '').strip()
    if not name or len(name) > max_length:
        abort(400)
    return name


def _name_from_body():
    return _clean_name((request.get_json(silent=True) or {}).get('name'))


@bp.route('/me')
@auth.require_user
def me():
    user = db.first(db.table('users').select('id', 'email').eq('id', g.user_id).execute())
    roles = {
        m['household_id']: m['role']
        for m in db.table('memberships').select('household_id', 'role').eq('user_id', g.user_id).execute().data
    }
    households = db.table('households').select('id', 'name').in_('id', list(roles)).order('created_at').execute().data if roles else []
    return jsonify({
        'id': user['id'],
        'email': user['email'],
        'households': [{'id': h['id'], 'name': h['name'], 'role': roles[h['id']]} for h in households],
    })


@bp.route('/households', methods=['POST'])
@auth.require_user
def create_household():
    name = _name_from_body()
    household_id = db.new_id()
    ts = db.now()
    db.table('households').insert({
        'id': household_id, 'name': name, 'owner_user_id': g.user_id, 'created_at': ts,
    }).execute()
    db.table('memberships').insert({
        'user_id': g.user_id, 'household_id': household_id, 'role': 'owner', 'created_at': ts,
    }).execute()
    signaling.refresh_user_memberships(g.user_id)
    return jsonify({'id': household_id, 'name': name, 'role': 'owner'}), 201


@bp.route('/households/<household_id>/pairing-codes', methods=['POST'])
@auth.require_user
def create_pairing_code(household_id):
    """Mints a short-lived, single-use code for adding a camera to this
    household. Viewer Mode shows it as a QR code that the camera phone scans
    and redeems at POST /devices/pair."""
    auth.require_member(household_id, roles=db.MANAGER_ROLES)
    code = _new_pairing_code()
    expires_at = db.now() + PAIRING_CODE_TTL_SECONDS
    db.table('pairing_codes').insert({
        'code': code, 'household_id': household_id, 'created_by': g.user_id, 'expires_at': expires_at,
    }).execute()
    return jsonify({'code': code, 'expires_at': expires_at}), 201


@bp.route('/devices/pair', methods=['POST'])
def pair_device():
    """Unauthenticated by design: possession of an unexpired pairing code is
    the credential. Trades it for a device token, which is returned exactly
    once and only stored server-side as a hash."""
    body = request.get_json(silent=True) or {}
    code = (body.get('code') or '').strip().upper()
    name = _clean_name(body.get('name'))

    ts = db.now()
    # Claiming the code with a single conditional UPDATE (rather than SELECT
    # then UPDATE) means two cameras racing on the same code can't both win
    # it: Postgres applies the filter and the write atomically, and only the
    # winner gets the row back.
    claimed = db.first(
        db.table('pairing_codes')
        .update({'used_at': ts})
        .eq('code', code)
        .is_('used_at', 'null')
        .gt('expires_at', ts)
        .execute()
    )
    if claimed is None:
        abort(400)
    household_id = claimed['household_id']

    device_id = db.new_id()
    token = auth.new_device_token()
    db.table('devices').insert({
        'id': device_id,
        'household_id': household_id,
        'name': name,
        'token_hash': auth.hash_device_token(token),
        'created_at': ts,
    }).execute()

    signaling.broadcast_roster(household_id)
    return jsonify({
        'device_id': device_id,
        'device_token': token,
        'household_id': household_id,
        'name': name,
    }), 201


@bp.route('/devices/me', methods=['PATCH'])
@auth.require_device
def rename_own_device():
    """Lets a camera rename itself from Camera Mode, using its device token."""
    name = _name_from_body()
    device = g.device
    db.table('devices').update({'name': name}).eq('id', device['id']).execute()
    signaling.device_renamed(device['id'], device['household_id'], name)
    return jsonify({'id': device['id'], 'name': name})


def device_or_404(device_id):
    """A paired (non-revoked) camera by the id in a URL, or a 404. Callers
    still check the user's membership in its household."""
    if not db.is_id(device_id):
        abort(404)
    device = db.first(
        db.table('devices').select('*').eq('id', device_id).is_('revoked_at', 'null').execute()
    )
    if device is None:
        abort(404)
    return device


def _managed_device_or_404(device_id):
    """A camera the calling user may rename or remove: an owner or admin
    of its household."""
    device = device_or_404(device_id)
    auth.require_member(device['household_id'], roles=db.MANAGER_ROLES)
    return device


@bp.route('/devices/<device_id>', methods=['PATCH'])
@auth.require_user
def rename_device(device_id):
    device = _managed_device_or_404(device_id)
    name = _name_from_body()
    db.table('devices').update({'name': name}).eq('id', device_id).execute()
    signaling.device_renamed(device_id, device['household_id'], name)
    return jsonify({'id': device_id, 'name': name})


DETECTION_MODES = ('person', 'any')


@bp.route('/devices/<device_id>/settings', methods=['PATCH'])
@auth.require_user
def update_device_settings(device_id):
    """A camera's settings, changed from Viewer Mode. For now that's only its
    detection mode: open motion events for people only, or for any motion."""
    device = _managed_device_or_404(device_id)
    mode = (request.get_json(silent=True) or {}).get('detection_mode')
    if mode not in DETECTION_MODES:
        abort(400)
    db.table('devices').update({'detection_mode': mode}).eq('id', device_id).execute()
    device['detection_mode'] = mode
    signaling.device_settings_changed(device)
    return jsonify({'id': device_id, 'detection_mode': mode})


@bp.route('/devices/<device_id>', methods=['DELETE'])
@auth.require_user
def revoke_device(device_id):
    """Removes a camera from its household: its token stops working
    immediately and any live connection is dropped."""
    device = _managed_device_or_404(device_id)
    db.table('devices').update({'revoked_at': db.now()}).eq('id', device_id).execute()
    signaling.device_revoked(device_id, device['household_id'])
    return '', 204


INVITE_ROLES = ('admin', 'viewer')
INVITE_TTL_SECONDS = 7 * 24 * 60 * 60


@bp.route('/households/<household_id>/invites', methods=['POST'])
@auth.require_user
def create_invite(household_id):
    """Mints a week-long code for adding another person to this household,
    as an admin or a viewer. Shown to share however the inviter likes (text,
    QR); redeemed at POST /invites/accept."""
    auth.require_member(household_id, roles=db.MANAGER_ROLES)
    role = (request.get_json(silent=True) or {}).get('role', 'viewer')
    if role not in INVITE_ROLES:
        abort(400)
    code = _new_pairing_code()
    expires_at = db.now() + INVITE_TTL_SECONDS
    db.table('invites').insert({
        'code': code, 'household_id': household_id, 'role': role,
        'created_by': g.user_id, 'expires_at': expires_at,
    }).execute()
    return jsonify({'code': code, 'role': role, 'expires_at': expires_at}), 201


@bp.route('/households/<household_id>/invites')
@auth.require_user
def list_invites(household_id):
    """Outstanding (unredeemed) invites for this household, so a manager can
    see what's pending and revoke one."""
    auth.require_member(household_id, roles=db.MANAGER_ROLES)
    rows = (
        db.table('invites')
        .select('code', 'role', 'expires_at')
        .eq('household_id', household_id)
        .is_('used_at', 'null')
        .order('expires_at')
        .execute()
        .data
    )
    return jsonify(rows)


@bp.route('/households/<household_id>/invites/<code>', methods=['DELETE'])
@auth.require_user
def revoke_invite(household_id, code):
    """Cancels a pending invite before it's redeemed."""
    auth.require_member(household_id, roles=db.MANAGER_ROLES)
    invite = db.first(
        db.table('invites')
        .select('code')
        .eq('code', code)
        .eq('household_id', household_id)
        .is_('used_at', 'null')
        .execute()
    )
    if invite is None:
        abort(404)
    db.table('invites').delete().eq('code', code).execute()
    return '', 204


@bp.route('/invites/accept', methods=['POST'])
@auth.require_user
def accept_invite():
    """Trades an invite code for membership in its household, at the role
    the invite was minted for."""
    code = ((request.get_json(silent=True) or {}).get('code') or '').strip().upper()
    ts = db.now()
    invite = db.first(
        db.table('invites').select('household_id', 'role').eq('code', code)
        .is_('used_at', 'null').gt('expires_at', ts).execute()
    )
    if invite is None:
        abort(400)
    household_id = invite['household_id']
    if auth.role_in(g.user_id, household_id) is not None:
        # Already a member: leave the invite unredeemed, so it still works
        # for whoever else it was meant for.
        abort(409)

    # Claiming with a single conditional UPDATE, as in /devices/pair, so two
    # people redeeming the same code at once can't both win it.
    claimed = db.first(
        db.table('invites')
        .update({'used_at': ts, 'used_by': g.user_id})
        .eq('code', code)
        .is_('used_at', 'null')
        .gt('expires_at', ts)
        .execute()
    )
    if claimed is None:
        abort(400)
    db.table('memberships').insert({
        'user_id': g.user_id, 'household_id': household_id, 'role': invite['role'], 'created_at': ts,
    }).execute()
    household = db.first(db.table('households').select('name').eq('id', household_id).execute())
    signaling.refresh_user_memberships(g.user_id)
    return jsonify({'household_id': household_id, 'household_name': household['name'], 'role': invite['role']})

