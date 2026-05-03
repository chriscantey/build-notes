# Reference Code

Working source files from a running voice-server install. Sanitized to remove hostnames, paths, and credentials. They're real files, not toy examples — adapt them to your setup.

| File | What it does |
|------|-------------|
| `docker-compose.yml` | Two services on a shared Docker network. Mounts `.env` and TLS certs as read-only volumes. |
| `Dockerfile` | Bun base image, copies `package.json` and `src/`, exposes ports 8888 (HTTP) and 8889 (HTTPS). |
| `package.json` | Bun project file. No dependencies — Bun ships with WebSocket and TLS built in. |
| `server.ts` | The main server. HTTP route handler, provider router (Chatterbox primary with Kokoro fallback), WebSocket broadcaster with backpressure + dead-socket detection, HTTPS listener that no-ops if certs are missing, heartbeat that prunes stale clients. |
| `kokoro/Dockerfile` | Builds on the Kokoro project's `kokoro-tts-cpu:local` base image (you build that separately). Just adds the HTTP wrapper. |
| `kokoro/server.py` | Python HTTP server wrapping `KPipeline`. Handles per-language pipeline lazy loading, warmup pass to dodge the first-generation NaN bug, NaN auto-recovery on subsequent calls. |

## Environment variables

The server reads everything from a `.env` file mounted at `/app/.env`. Minimum config for a local-only Kokoro setup:

```
TTS_PRIMARY=kokoro
KOKORO_URL=http://voice-server-kokoro:7880
KOKORO_VOICE=bf_emma
PAI_VOICE_STREAM_PORT=8888
PAI_VOICE_WSS_PORT=8889
```

If you want hosted providers as the primary or as alternates, add the relevant URL/key pairs. The reference `server.ts` includes Chatterbox handling as an example; ElevenLabs and Google would each be a similar `generateSpeech*` function plus a case in the router.

## What you'll edit before building

**1. The shared Docker network.** Create it once: `docker network create voice-net`. The reference compose file uses `voice-net` as a generic name — feel free to rename, just keep it consistent across both services.

**2. The volume mounts in `docker-compose.yml`.** Adjust the host-side paths to wherever you keep your config and certs. The reference uses `./config/` and `./certs/` relative to the compose file, which is a clean default if you don't have an existing structure.

**3. The base image for the Kokoro sidecar.** The reference Dockerfile expects `kokoro-tts-cpu:local` to already exist. The Kokoro project has Docker setup steps for building this image; do that first, then `docker compose up -d --build` will work.

**4. TLS certs.** Drop your `fullchain.pem` and `privkey.pem` in the certs directory. If you don't have certs (or don't need HTTPS), skip this — the HTTPS listener silently no-ops and the HTTP listener still works.

## What you don't need

- A web framework. Bun's built-in HTTP and WebSocket server is the whole HTTP layer.
- A separate process manager. `docker compose up -d --build` and the `restart: unless-stopped` policy handle restart-on-crash.
- A reverse proxy. Both HTTP and HTTPS listen directly. If you want a proxy in front for routing or rate limiting, you can add one — but it's not required.
- A schema validation library. The `/notify` endpoint takes loose JSON and pulls the fields it needs. For a single-user system this is fine; for anything multi-tenant, add validation.

## Provider voice formats

Each provider uses its own voice naming convention:

- **Kokoro:** `[lang][gender]_[name]` (e.g., `bf_emma`, `am_adam`, `jf_alpha`). The first letter is the language: `a` American English, `b` British English, `j` Japanese.
- **Chatterbox:** filename without extension. Voices are `.wav` files in the Chatterbox `voices/` directory.
- **ElevenLabs:** opaque IDs from your ElevenLabs account (e.g., `21m00Tcm4TlvDq8ikWAM`).
- **Google Cloud TTS:** dotted names (e.g., `en-US-Neural2-J`).

The `voice_name` parameter in `/notify` requests passes straight through to the active provider, so it must match that provider's format.
