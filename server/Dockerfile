# syntax=docker/dockerfile:1
FROM python:3.12-slim

# Prevents Python from writing pyc files, and keeps stdout/stderr unbuffered
# so logs aren't lost if the process crashes.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY *.py ./

# Clips are kept here only with a local SQLite database (SQLITE_PATH); with
# Supabase they go to the Storage bucket.
RUN useradd --create-home app && mkdir -p /app/data && chown app /app/data
USER app

EXPOSE 5050
# One worker: presence state is per-process (see signaling.py). Each open
# Socket.IO connection holds a thread, so --threads caps concurrent clients.
CMD ["gunicorn", "--workers", "1", "--threads", "100", "--bind", "0.0.0.0:5050", "wsgi:app"]
