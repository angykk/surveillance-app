import os

from dotenv import load_dotenv
from flask import Flask

import clip_storage
import db
import households
import livekit_rooms
import motion
import retention
import signaling
from sqlite_client import SQLiteClient

# Relative paths in the config (SQLITE_PATH, RECORDINGS_DIR) resolve against
# server/, whatever directory the server is started from.
SERVER_DIR = os.path.dirname(os.path.abspath(__file__))


def create_app(overrides=None):
    """Builds the app from environment config (see .env.example).

    `overrides` lets tests swap in a temp database/clips dir and a test JWT
    secret without touching the environment."""
    app = Flask(__name__)
    app.config.update(
        # `or` rather than a get() default, so a blank line in .env still
        # falls back to the default.
        # Where clips are kept with a local SQLite database (local testing).
        # With Supabase they go to the CLIP_BUCKET Storage bucket instead.
        RECORDINGS_DIR=os.environ.get('RECORDINGS_DIR') or os.path.join('data', 'recordings'),
        CLIP_BUCKET=os.environ.get('CLIP_BUCKET') or 'clips',
        # Signs LocalStorage's clip URLs. A random one per process is fine:
        # cameras ask for a fresh upload URL on every try.
        SECRET_KEY=os.environ.get('SECRET_KEY') or os.urandom(32),
        # Motion events and their clips older than this are deleted (0 keeps
        # them forever); checked every RETENTION_INTERVAL_S.
        RETENTION_DAYS=int(os.environ.get('RETENTION_DAYS') or '30'),
        RETENTION_INTERVAL_S=int(os.environ.get('RETENTION_INTERVAL_S') or '3600'),
        SUPABASE_URL=os.environ.get('SUPABASE_URL', ''),
        SUPABASE_KEY=os.environ.get('SUPABASE_KEY', ''),
        SUPABASE_JWT_SECRET=os.environ.get('SUPABASE_JWT_SECRET', ''),
        # Keeps data in a local SQLite file instead of the Supabase project
        # (local testing). Sign-in still goes through Supabase Auth.
        SQLITE_PATH=os.environ.get('SQLITE_PATH', ''),
        # The LiveKit server that carries live video. LIVEKIT_URL is handed
        # to the phones as-is, so it must be reachable from them (a LAN IP or
        # public host, not localhost).
        LIVEKIT_URL=os.environ.get('LIVEKIT_URL', ''),
        LIVEKIT_API_KEY=os.environ.get('LIVEKIT_API_KEY', ''),
        LIVEKIT_API_SECRET=os.environ.get('LIVEKIT_API_SECRET', ''),
        # Caps request bodies, including clip uploads to LocalStorage;
        # Werkzeug rejects anything larger with a 413.
        MAX_CONTENT_LENGTH=int(os.environ.get('MAX_UPLOAD_MB') or '200') * 1024 * 1024,
    )
    if overrides:
        app.config.update(overrides)

    if not app.config['SUPABASE_URL'] and not app.config['SUPABASE_JWT_SECRET']:
        raise RuntimeError('Set SUPABASE_URL (and SUPABASE_JWT_SECRET for legacy HS256 projects) to verify sign-ins.')

    if app.config['SQLITE_PATH']:
        path = os.path.join(SERVER_DIR, app.config['SQLITE_PATH'])
        os.makedirs(os.path.dirname(path), exist_ok=True)
        db.use_client(SQLiteClient(path))
        print(f'Using local SQLite database {path}')
        app.config['RECORDINGS_DIR'] = os.path.join(SERVER_DIR, app.config['RECORDINGS_DIR'])
        os.makedirs(app.config['RECORDINGS_DIR'], exist_ok=True)
        app.extensions['clip_storage'] = clip_storage.LocalStorage(app.config['RECORDINGS_DIR'], app.config['SECRET_KEY'])
    elif app.config['SUPABASE_URL'] and app.config['SUPABASE_KEY']:
        client = db.init_client(app.config['SUPABASE_URL'], app.config['SUPABASE_KEY'])
        app.extensions['clip_storage'] = clip_storage.SupabaseStorage(client, app.config['CLIP_BUCKET'])
    else:
        raise RuntimeError('Set SUPABASE_KEY (the secret key), or SQLITE_PATH for a local database, in .env.')
    signaling.close_orphaned_motion_events()

    if not (app.config['LIVEKIT_URL'] and app.config['LIVEKIT_API_KEY'] and app.config['LIVEKIT_API_SECRET']):
        raise RuntimeError('Set LIVEKIT_URL, LIVEKIT_API_KEY and LIVEKIT_API_SECRET in .env for live video.')
    livekit_rooms.init(app.config['LIVEKIT_URL'], app.config['LIVEKIT_API_KEY'], app.config['LIVEKIT_API_SECRET'])

    app.register_blueprint(households.bp)
    app.register_blueprint(motion.bp)
    app.register_blueprint(clip_storage.bp)

    # The mobile app isn't a browser, so CORS only matters for a future web
    # client; it's closed unless origins are listed explicitly.
    cors_origins = [o for o in os.environ.get('CORS_ORIGINS', '').split(',') if o]
    signaling.socketio.init_app(app, async_mode='threading', cors_allowed_origins=cors_origins or None)

    # Tests call retention.run_once themselves.
    if not app.config.get('TESTING'):
        retention.start(app)
    return app


if __name__ == '__main__':
    # Local development only: production runs under gunicorn (see wsgi.py).
    load_dotenv()
    app = create_app()
    # Debug mode exposes the Werkzeug debugger (arbitrary code execution) to
    # anyone who can reach the server, so it's opt-in for local development.
    debug = os.environ.get('FLASK_DEBUG') == '1'
    signaling.socketio.run(app, host='0.0.0.0', port=5050, debug=debug, allow_unsafe_werkzeug=True)
