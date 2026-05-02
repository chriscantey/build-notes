# Reference Code

Working source files from a running Hypercast install. Sanitized to remove hostnames, secrets, and personal infrastructure references.

These are real files, not toy examples. They aren't production-hardened and shouldn't be deployed to the public internet as-is. Use them to understand the patterns, then adapt for your own setup.

| File | What it does |
|------|-------------|
| `docker-compose.yml` | Container setup. One service, four mounted volumes (audio, images, assets, data), shared external networks for talking to Ollama on the host and Chatterbox TTS in another container. One worker, 60-minute timeout for long episodes. |
| `Dockerfile` | Python 3.11 base plus ffmpeg and Bun. Installs Python deps from `requirements.txt` and Readability deps from `readability/package.json`. Single gunicorn worker so the in-process GPU lock works. |
| `config.py` | Centralized config. Everything reads from environment variables with sane defaults — no personal data in the file itself. |
| `auth.py` | X-API-Key middleware. Single shared key, constant-time comparison via `hmac.compare_digest`. |
| `create.py` | The POST /create route. Validates synchronously (so bad input gets a meaningful 400), then hands off to a daemon thread and returns 202. |
| `background_tasks.py` | Daemon thread runner with a process-wide `threading.Lock` so Ollama and Chatterbox never fight for the GPU. |
| `content_service.py` | URL detection, fetch, Mozilla Readability subprocess, BeautifulSoup fallback (boilerplate regex blocks trimmed — see project source for the full pattern list), Ollama via native `/api/chat` with `think:false`, OpenAI/Gemini alternates, title and summary generation, and the `process_validated_input` packager. |
| `tts_service.py` | Markdown stripping with structural pauses preserved, ~500-word paragraph-boundary segmentation, per-segment TTS calls with progress logging, audio assembly with intro sound, MP3 export, SQLite write. |
| `feed_service.py` | RSS 2.0 generation with the iTunes namespace. Generated on each request from the database. |

## What you'd add for your own setup

- `wsgi.py` — One-liner that imports `create_app()` and exposes `app` for gunicorn.
- `app/__init__.py` — Flask app factory with logging config and blueprint registration.
- `app/routes/feed.py` and `app/routes/index.py` — The `/feed` and `/` routes (small, generated from the same patterns shown here).
- `app/services/database_service.py` — SQLite singleton with one table and two methods (insert, select all). Trivial to write from scratch.
- `readability/extract.js` — A short Bun script that reads HTML from stdin, runs `@mozilla/readability`, and prints JSON. The Mozilla Readability docs cover this directly.
- `templates/` — Jinja templates for the web UI. Optional — many users only need the API and feed.
- `assets/intro-sound.mp3` and `app/static/images/podcast-cover.png` — Your own audio sting and cover art. The default install doesn't ship these.
- `.env.example` — Template for the environment variables config.py reads.

## Voices

The setup in this note assumes Chatterbox TTS as a sidecar container exposing an OpenAI-compatible `/v1/audio/speech` endpoint. Voice names map to `.wav` files in the Chatterbox `voices/` directory. If you'd rather use OpenAI's hosted TTS, set `OPENAI_BASE_URL` to `https://api.openai.com/v1`, set `TTS_VOICE` to one of OpenAI's voice names (`alloy`, `echo`, `fable`, `onyx`, `nova`, `shimmer`), and provide an `OPENAI_API_KEY`. No code changes needed.

For local TTS without a GPU, [Kokoro](https://github.com/hexgrad/kokoro) is a good alternative. It's CPU-friendly, Apache-licensed, and exposes the same OpenAI-compatible interface.
