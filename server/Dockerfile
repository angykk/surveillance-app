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

# Recordings live here; mount a volume to keep them.
RUN useradd --create-home app && mkdir -p /app/data && chown app /app/data
USER app

EXPOSE 5050
CMD ["python", "web_rtc.py"]
