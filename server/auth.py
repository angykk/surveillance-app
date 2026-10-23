import functools
import hashlib
import secrets

import jwt
from flask import abort, current_app, g, request

import db

# Two kinds of caller, each with its own credential:
# - Users (Viewer Mode) sign in with Supabase Auth and send its access token
#   as `Authorization: Bearer <jwt>`. This server only verifies the token; it
#   never sees passwords.
# - Devices (Camera Mode) are paired into a household via a QR code and get
#   a long-lived device token, sent as `Authorization: Device <token>`. That
#   way an unattended camera phone never holds a full user session.

_jwks_client = None


def _jwks():
    global _jwks_client
    if _jwks_client is None:
        url = current_app.config['SUPABASE_URL'].rstrip('/')
        _jwks_client = jwt.PyJWKClient(f'{url}/auth/v1/.well-known/jwks.json', cache_keys=True)
    return _jwks_client


def verify_user_token(token):
    """Returns the decoded Supabase JWT claims, or None if the token is
    missing, expired, or not signed by this project.

    Projects on Supabase's legacy shared-secret signing set
    SUPABASE_JWT_SECRET (HS256); projects on asymmetric signing keys only
    need SUPABASE_URL, and keys are fetched from its JWKS endpoint."""
    if not token:
        return None
    secret = current_app.config.get('SUPABASE_JWT_SECRET')
    try:
        if secret:
            return jwt.decode(token, secret, algorithms=['HS256'], audience='authenticated')
        signing_key = _jwks().get_signing_key_from_jwt(token)
        url = current_app.config['SUPABASE_URL'].rstrip('/')
        return jwt.decode(
            token,
            signing_key.key,
            algorithms=['ES256', 'RS256'],
            audience='authenticated',
            issuer=f'{url}/auth/v1',
        )
    except jwt.PyJWTError:
        return None


def ensure_user(claims):
    """Makes sure the app-side user row exists for a verified token, giving
    a brand-new user a default household (see `provision_user` in
    supabase/schema.sql) so they can pair a camera right away without a
    separate setup step. Returns the user id."""
    user_id = claims['sub']
    if db.first(db.table('users').select('id').eq('id', user_id).limit(1).execute()) is None:
        db.client.rpc('provision_user', {'p_user_id': user_id, 'p_email': claims.get('email')}).execute()
    return user_id


def hash_device_token(token):
    return hashlib.sha256(token.encode()).hexdigest()


def new_device_token():
    return secrets.token_urlsafe(32)


def device_for_token(token):
    """Returns the (non-revoked) device row for a device token, or None."""
    if not token:
        return None
    return db.first(
        db.table('devices')
        .select('*')
        .eq('token_hash', hash_device_token(token))
        .is_('revoked_at', 'null')
        .limit(1)
        .execute()
    )


def _authorization(scheme):
    header = request.headers.get('Authorization', '')
    prefix = f'{scheme} '
    return header[len(prefix):].strip() if header.startswith(prefix) else None


def require_user(view):
    @functools.wraps(view)
    def wrapper(*args, **kwargs):
        claims = verify_user_token(_authorization('Bearer'))
        if claims is None:
            abort(401)
        g.user_id = ensure_user(claims)
        return view(*args, **kwargs)
    return wrapper


def require_device(view):
    @functools.wraps(view)
    def wrapper(*args, **kwargs):
        device = device_for_token(_authorization('Device'))
        if device is None:
            abort(401)
        g.device = device
        return view(*args, **kwargs)
    return wrapper


def role_in(user_id, household_id):
    """The user's role in a household, or None if they aren't a member."""
    row = db.first(
        db.table('memberships')
        .select('role')
        .eq('user_id', user_id)
        .eq('household_id', household_id)
        .limit(1)
        .execute()
    )
    return row['role'] if row else None


def household_ids_of(user_id):
    rows = db.table('memberships').select('household_id').eq('user_id', user_id).execute().data
    return {row['household_id'] for row in rows}


def require_member(household_id, roles=db.ROLES):
    """Aborts unless the current user has one of `roles` in the household.

    Non-members get 404 rather than 403, so household ids can't be probed
    for existence."""
    role = role_in(g.user_id, household_id) if db.is_id(household_id) else None
    if role is None:
        abort(404)
    if role not in roles:
        abort(403)
    return role
