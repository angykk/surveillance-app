# Surveillance App

Turn a phone into a security camera and watch it live from another device. One phone runs in **Camera Mode** (streams video and records motion clips), another runs in **Viewer Mode** (watches the live feed and browses recordings). A small signaling/storage server pairs the two over WebRTC and stores uploaded recordings.

## Structure

- `mobile/` — Flutter app (Camera Mode + Viewer Mode)
- `server/` — Flask + Socket.IO server: WebRTC signaling relay and recordings storage/API

## Server

```
cd server
pip install -r requirements.txt
python web_rtc.py
```

Runs on `0.0.0.0:5050`. Recording metadata is stored in a local SQLite DB (`server/data/recordings.db`); clip files are saved under `server/data/recordings/`.

## Mobile app

```
cd mobile
cp .env.example .env   # set SERVER_IP to your server's address
flutter pub get
flutter run
```

On launch, pick **Camera Mode** to stream and record motion clips, or **Viewer Mode** to browse connected cameras and watch/play back recordings.

## How it works

- Cameras and viewers connect to the server over Socket.IO and identify their role (`camera` or `viewer`).
- A viewer picks a camera from the live roster; the server relays WebRTC offer/answer/ICE messages between that pair so video streams peer-to-peer.
- The camera device detects motion locally and uploads clips to the server, which viewers can then list and play back per camera.
