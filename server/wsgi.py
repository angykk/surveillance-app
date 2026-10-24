from dotenv import load_dotenv

from app import create_app

# The production entry point (see the Dockerfile): gunicorn with a single
# worker process, since presence state in signaling.py is per-process, and
# threads for concurrency, matching Flask-SocketIO's 'threading' mode.
load_dotenv()
app = create_app()
