# Surveillance App

Turn a spare phone into a security camera and watch it from another phone.

- **Camera Mode:** streams live video and records a clip whenever it detects motion.
- **Viewer Mode:** signs in, shows your cameras, and plays the live feed next to a timeline of motion events. Tap an event to play its clip.

## Structure

- `mobile/`: the Flutter app, with both modes.
- `server/`: a Flask + Socket.IO server. It handles WebRTC signaling, camera pairing, motion events and clips.

## 1. Supabase project

Sign-in always goes through Supabase Auth, so you need a project even for local testing.

1. Create a project at [supabase.com](https://supabase.com).
2. **Authentication → Providers:** keep Email on. For testing, turn off "Confirm email".
3. Note the **Project URL**, the **publishable key** (`sb_publishable_…`) and the **secret key** (`sb_secret_…`). They're under **Project Settings → API Keys**.

## 2. Server

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

Start the server:

```
python web_rtc.py
```

It listens on `0.0.0.0:5050`. Clips are saved under `server/data/recordings/`.

## 3. Mobile app

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

Both phones must be able to reach `SERVER_IP`. For now, put them on the same Wi-Fi as the server.

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
