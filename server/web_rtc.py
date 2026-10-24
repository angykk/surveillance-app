import os

from dotenv import load_dotenv
from flask import Flask

import db
import households
import livekit_rooms
import motion
import signaling
from sqlite_client import SQLiteClient

DATA_DIR = os.path.join(os.path.dirname(__file__), 'data')


def create_app(overrides=None):
    """Builds the app from environment config (see .env.example).

    `overrides` lets tests swap in a temp database/clips dir and a test JWT
    secret without touching the environment."""
    app = Flask(__name__)
    app.config.update(
        # `or` rather than a get() default, so a blank line in .env still
        # falls back to the default.
        RECORDINGS_DIR=os.environ.get('RECORDINGS_DIR') or os.path.join(DATA_DIR, 'recordings'),
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
        # Caps clip uploads; Werkzeug rejects anything larger with a 413
        # before it's written to disk.
        MAX_CONTENT_LENGTH=int(os.environ.get('MAX_UPLOAD_MB', '200')) * 1024 * 1024,
    )
    if overrides:
        app.config.update(overrides)

    if not app.config['SUPABASE_URL'] and not app.config['SUPABASE_JWT_SECRET']:
        raise RuntimeError('Set SUPABASE_URL (and SUPABASE_JWT_SECRET for legacy HS256 projects) to verify sign-ins.')

    if app.config['SQLITE_PATH']:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), app.config['SQLITE_PATH'])
        os.makedirs(os.path.dirname(path), exist_ok=True)
        db.use_client(SQLiteClient(path))
        print(f'Using local SQLite database {path}')
    elif app.config['SUPABASE_URL'] and app.config['SUPABASE_KEY']:
        db.init_client(app.config['SUPABASE_URL'], app.config['SUPABASE_KEY'])
    else:
        raise RuntimeError('Set SUPABASE_KEY (the secret key), or SQLITE_PATH for a local database, in .env.')

    if not (app.config['LIVEKIT_URL'] and app.config['LIVEKIT_API_KEY'] and app.config['LIVEKIT_API_SECRET']):
        raise RuntimeError('Set LIVEKIT_URL, LIVEKIT_API_KEY and LIVEKIT_API_SECRET in .env for live video.')
    livekit_rooms.init(app.config['LIVEKIT_URL'], app.config['LIVEKIT_API_KEY'], app.config['LIVEKIT_API_SECRET'])

    os.makedirs(app.config['RECORDINGS_DIR'], exist_ok=True)

    app.register_blueprint(households.bp)
    app.register_blueprint(motion.bp)

    # The mobile app isn't a browser, so CORS only matters for a future web
    # client; it's closed unless origins are listed explicitly.
    cors_origins = [o for o in os.environ.get('CORS_ORIGINS', '').split(',') if o]
    signaling.socketio.init_app(app, async_mode='threading', cors_allowed_origins=cors_origins or None)
    return app


if __name__ == '__main__':
    load_dotenv()
    app = create_app()
    # Debug mode exposes the Werkzeug debugger (arbitrary code execution) to
    # anyone who can reach the server, so it's opt-in for local development.
    debug = os.environ.get('FLASK_DEBUG') == '1'
    signaling.socketio.run(app, host='0.0.0.0', port=5050, debug=debug, allow_unsafe_werkzeug=True)
