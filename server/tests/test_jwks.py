import time
from types import SimpleNamespace

import jwt
from cryptography.hazmat.primitives.asymmetric import ec

import auth
from web_rtc import create_app

SUPABASE_URL = 'https://example-ref.supabase.co'


def test_asymmetric_supabase_tokens_verify_via_jwks(tmp_path, monkeypatch):
    app = create_app({
        'SQLITE_PATH': str(tmp_path / 'test.db'),
        'RECORDINGS_DIR': str(tmp_path / 'recordings'),
        'SUPABASE_URL': SUPABASE_URL,
        'SUPABASE_JWT_SECRET': '',
    })
    key = ec.generate_private_key(ec.SECP256R1())
    other_key = ec.generate_private_key(ec.SECP256R1())
    # Stand-in for the project's JWKS endpoint, serving only `key`.
    monkeypatch.setattr(auth, '_jwks', lambda: SimpleNamespace(
        get_signing_key_from_jwt=lambda _: SimpleNamespace(key=key.public_key()),
    ))

    def token(signing_key, issuer=f'{SUPABASE_URL}/auth/v1'):
        claims = {'sub': 'alice', 'aud': 'authenticated', 'iss': issuer, 'exp': int(time.time()) + 60}
        return jwt.encode(claims, signing_key, algorithm='ES256')

    client = app.test_client()
    assert client.get('/me', headers={'Authorization': f'Bearer {token(key)}'}).status_code == 200
    assert client.get('/me', headers={'Authorization': f'Bearer {token(other_key)}'}).status_code == 401
    wrong_issuer = token(key, issuer='https://attacker.supabase.co/auth/v1')
    assert client.get('/me', headers={'Authorization': f'Bearer {wrong_issuer}'}).status_code == 401
