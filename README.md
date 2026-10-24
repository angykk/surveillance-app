# Surveillance App

Turn a spare phone into a security camera and watch it from another phone.

- **Camera Mode:** streams live video and records a clip whenever it detects motion.
- **Viewer Mode:** signs in, shows your cameras, and plays the live feed next to a timeline of motion events. Tap an event to play its clip. Several phones can watch the same camera at once.

## Structure

- `mobile/`: the Flutter app, with both modes.
- `server/`: a Flask + Socket.IO server. It handles sign-in checks, camera pairing, motion events, clips, and who may watch which camera.
- **LiveKit** carries the live video. Each camera has its own room. The Flask server gives out a room token only after checking that the viewer belongs to the camera's household. A camera joins its room only while someone is watching, and keeps detecting motion and recording clips either way.

## 1. Supabase project

Sign-in always goes through Supabase Auth, so you need a project even for local testing.

1. Create a project at [supabase.com](https://supabase.com).
2. **Authentication → Providers:** keep Email on. For testing, turn off "Confirm email".
3. Note the **Project URL**, the **publishable key** (`sb_publishable_…`) and the **secret key** (`sb_secret_…`). They're under **Project Settings → API Keys**.

## 2. LiveKit

Run a local LiveKit server in dev mode. Dev mode uses the API key `devkey` and the secret `secret`.

```
docker run --rm -p 7880:7880 -p 7881:7881 -p 7882:7882/udp \
  livekit/livekit-server:v1.13.9 --dev --bind 0.0.0.0 --node-ip <your computer's LAN IP>
```

Without Docker, run `brew install livekit`, then `livekit-server --dev --bind 0.0.0.0 --node-ip <LAN IP>`.

`--node-ip` matters: it's the address LiveKit gives the phones for the media connection, so it has to be reachable from them.

## 3. Server

```
cd server
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Then pick where the server keeps its data, and set `server/.env` to match.

**Local testing (SQLite):** data lives in a local file. No schema step or secret key is needed.

```
SUPABASE_URL=https://<project-ref>.supabase.co
SQLITE_PATH=data/local.db
```

**Supabase database:**

1. In the project's **SQL Editor**, run `server/supabase/schema.sql`. It's safe to re-run.
2. Set `server/.env`:

   ```
   SUPABASE_URL=https://<project-ref>.supabase.co
   SUPABASE_KEY=sb_secret_...
   ```

   Use the secret key here, not the publishable one. Set `SUPABASE_JWT_SECRET` too if the project still uses legacy HS256 JWT signing.

Either way, point the server at LiveKit. The phones receive `LIVEKIT_URL` as-is, so use the LAN IP, not `localhost`:

```
LIVEKIT_URL=ws://<your computer's LAN IP>:7880
LIVEKIT_API_KEY=devkey
LIVEKIT_API_SECRET=secret
```

Start the server:

```
python web_rtc.py
```

It listens on `0.0.0.0:5050`. Clips are saved under `server/data/recordings/`.

## 4. Mobile app

```
cd mobile
cp .env.example .env
flutter pub get
flutter run
```

Set `mobile/.env` like this:

```
SERVER_IP=http://<your computer's LAN IP>:5050
SUPABASE_URL=https://<project-ref>.supabase.co
SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
```

Both phones must be able to reach `SERVER_IP` and LiveKit. For now, put them on the same Wi-Fi as the server.

## Trying it out

1. **Phone A:** choose **Viewer Mode**, create an account or sign in, then tap **Add camera** to show a pairing QR code.
2. **Phone B:** choose **Camera Mode**, name the camera, and scan the code.
3. On phone A, tap the camera to watch it live. Wave at it, and a motion event shows up in the timeline. Its clip becomes playable a few seconds after the motion stops.

Each phone remembers its mode. To change it, use **⚙ → Switch mode**.

## Tests

```
cd server && pip install -r requirements-dev.txt && python -m pytest
cd mobile && flutter analyze && flutter test
```

The server tests use the SQLite backend, so they don't need a Supabase project.
