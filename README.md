# Surveillance App

Turn a phone into a security camera and watch it live from another device. One phone runs in **Camera Mode** (streams video and records motion clips), another runs in **Viewer Mode** (watches the live feed and browses recordings). A small signaling/storage server pairs the two over WebRTC and stores uploaded recordings.

## Structure

- `mobile/` — Flutter app (Camera Mode + Viewer Mode)
- `server/` — Flask + Socket.IO server: WebRTC signaling relay and recordings storage/API

## Accounts

Viewers sign in with [Supabase Auth](https://supabase.com/docs/guides/auth) (email + password). Each user gets a **Home** household on first sign-in; cameras are paired into a household, and a user only ever sees the cameras and recordings of households they belong to (as `owner`, `admin` or `viewer`).

Create a Supabase project, then:
- **Authentication → Providers:** keep Email enabled. For local testing you may want to turn off "Confirm email".
- **SQL Editor:** run `server/supabase/schema.sql` once (safe to re-run) to create the tables.
- **Project Settings → API Keys:** the publishable key goes in `mobile/.env`; the secret key (`sb_secret_…`) goes in `server/.env` as `SUPABASE_KEY`.
- **Project Settings → JWT Keys:** if the project still uses the legacy JWT secret, put it in `server/.env` as `SUPABASE_JWT_SECRET`. Projects on asymmetric signing keys don't need it.

## Server

```
cd server
pip install -r requirements.txt
cp .env.example .env   # set SUPABASE_URL and SUPABASE_KEY
python web_rtc.py
```

Runs on `0.0.0.0:5050`. Data lives in the Supabase project's Postgres, reached through the `supabase` Python client (the Data API) with the secret key. Clip files are saved under `server/data/recordings/<device_id>/`.

For local testing, set `SQLITE_PATH=data/local.db` in `server/.env` instead of `SUPABASE_KEY`: data then goes in a local SQLite file (created on startup, no schema step needed), while sign-in still goes through your Supabase project's Auth.

Tests: `pip install -r requirements-dev.txt && python -m pytest`. They use the local SQLite backend (`server/sqlite_client.py`), so they don't need a project.

## Mobile app

```
cd mobile
cp .env.example .env   # set SERVER_IP, SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY
flutter pub get
flutter run
```

1. On your phone, pick **Viewer Mode**, sign in, and tap **Add camera** to show a pairing QR code.
2. On the camera phone, pick **Camera Mode**, name it, and scan the code. It stays paired across restarts.
3. The camera appears in your list. Tap it to watch live or browse its recordings. Owners/admins can rename or remove cameras from the list's menu.

## How it works

- **Viewers** authenticate with their Supabase access token; **cameras** authenticate with a device token issued at pairing (stored hashed on the server, and in the phone's secure storage). Pairing codes are single-use and expire after 10 minutes.
- Both connect to the server over Socket.IO, presenting their credential in the handshake `auth` payload. Viewers receive a live roster of the cameras in their households; picking one sends `watch-camera`, which the server only honors for members of that camera's household. The server then relays WebRTC offer/answer/ICE messages between that pair so video streams peer-to-peer.
- The camera detects motion locally and uploads clips to the server, which members of its household can list and play back. Deleting recordings and managing cameras requires the `owner` or `admin` role.
- Removing a camera revokes its token and disconnects it immediately; it has to be paired again to rejoin.
