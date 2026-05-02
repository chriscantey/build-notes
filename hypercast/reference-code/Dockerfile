FROM python:3.11-slim

WORKDIR /app

# System dependencies for audio processing and Bun (used to run Mozilla Readability).
RUN apt-get update && apt-get install -y \
    ffmpeg \
    curl \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Bun for the Readability extraction subprocess.
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

# Python dependencies first for layer caching.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Readability dependencies (separate copy for caching).
COPY readability/package.json readability/
RUN cd readability && bun install

COPY . .

# Mount points for audio output, images, assets (intro sound, cover art), and SQLite.
RUN mkdir -p /app/app/static/audio /app/app/static/images /app/assets /app/data

ENV PYTHONUNBUFFERED=1
ENV FLASK_DEBUG=false
ENV SERVER_PORT=4973

EXPOSE 4973

# One worker because the app uses daemon threads with a process-wide GPU lock.
# Multiple workers would defeat the lock and re-introduce GPU contention.
CMD ["sh", "-c", "gunicorn --workers 1 --bind 0.0.0.0:${SERVER_PORT:-4973} wsgi:app"]
