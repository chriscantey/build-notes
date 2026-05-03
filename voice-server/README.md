# Voice Server

A small TTS broadcast service. You POST text to it, it generates speech, and it streams the resulting MP3 over WebSocket to every connected client at the same time. The point is that any audio device on your network — a Mac menu bar app, a browser tab, a Raspberry Pi with a speaker — can hear what the assistant says without the assistant having to know about each one individually.

The pipeline is pluggable. By default it tries a local Kokoro model first and falls back to other providers (ElevenLabs, Google Cloud TTS) on failure or by config. The whole thing is two Docker containers: a Bun + TypeScript front end that handles HTTP, WebSocket, and provider routing, and a Python sidecar that runs the Kokoro model.

## For AI assistants

If your user pointed you here, they're building (or thinking about) a personal voice notification system. Read this with them and ask: where they want voice to play (one Mac, multiple Macs, browser, dedicated speaker), whether they want all-local TTS or are okay paying for hosted (ElevenLabs and Google sound much better but cost per character), whether they have a GPU available (Kokoro runs fine on CPU but is faster on GPU), and whether they want to broadcast to multiple clients at once or just one. The `reference-code/` folder has the working source — sanitized hostnames and paths but otherwise complete. Build it for their setup, not mine.

The companion to this is the [assistant-voice](../assistant-voice/) build note — the macOS menu bar client that subscribes to this server's WebSocket and plays the audio as it arrives. The two notes are designed to be read together if you're building both ends of the system.

## Why I built this

Voice notifications used to be a browser thing. The assistant would generate a response, a hook would extract the spoken line, and a small page in a tab would play it. That worked but couldn't survive the realities of how I actually use my Mac — closing the tab killed audio, switching tabs throttled it, and you had to keep the page in the foreground for anything to play.

The fix had two halves. The client half is the [assistant-voice](../assistant-voice/) menu bar app — a native receiver that doesn't get throttled. This is the server half. It does three things the original setup didn't:

**Broadcast to multiple clients.** Any number of clients can connect to the WebSocket. When the assistant says something, every connected client gets the same MP3 at the same time. I have multiple Macs and a browser tab open on the desktop; they all play in sync.

**Let me swap providers without touching clients.** The server is the only thing that knows which TTS engine is generating the audio. If I change `TTS_PRIMARY` from Kokoro to ElevenLabs in the env file and restart, every client immediately gets ElevenLabs audio instead. The clients just play whatever bytes arrive.

**Run a local model.** ElevenLabs sounds great but costs money per character and ships my text to a third party. The Kokoro sidecar is the local alternative — Apache 2.0, runs on CPU, and produces decent voices in several languages. I use the local model 90% of the time and only flip to ElevenLabs when I want the quality.

The other thing this server does that's worth saying out loud: it's a place to put input sanitization. The assistant occasionally produces text with shell metacharacters, markdown, or other formatting that confuses TTS engines. Centralizing the cleanup in the server means clients never have to think about it.

## How the assistant uses it

The assistant's hook layer extracts the voice line from each AI response (the `🗣️ Assistant: …` line in my setup) and POSTs it to `/notify`. That's the entire integration. The hook doesn't know about voices, providers, or audio formats — it just sends a JSON object with a message field.

The server takes care of everything else: sanitizing the text, picking the active provider, generating audio, broadcasting to all connected clients, retrying on a different provider if the primary fails. The assistant never holds an audio buffer or talks to a TTS API directly. The decoupling means swapping the assistant or the TTS layer is a one-side change.

## Architecture

```
+-----------------------------+
|  AI Assistant (anywhere)    |
|  Hook extracts voice line   |
+--------------+--------------+
               | HTTPS POST /notify
               | { "message": "Deployment finished." }
               v
+----------------------------------------+
|  Voice Server (Bun + TypeScript)       |
|  +----------------+  +--------------+  |
|  | /notify route  |->| Provider     |  |
|  | Sanitize input |  | Router       |  |
|  +----------------+  +------+-------+  |
|                             |          |
|                  +----------+-------+  |
|                  v          v       v  |
|            Chatterbox    Kokoro  ElevenLabs / Google
|                            |
|                            v
|                  +--------------------+
|                  | Kokoro Sidecar     |
|                  | (Python + KPipeline|
|                  |  + ffmpeg MP3)     |
|                  +--------------------+
|                            |
|                            v
|                       MP3 bytes
|                            |
|                            v
|  +-----------------------------------+
|  | WebSocket broadcaster              |
|  | (sends to N connected clients)     |
|  +-----------------------------------+
+-------------------+--------------------+
                    |
                    | wss:// (binary frames)
                    v
       Clients (any number, any platform)
       e.g. assistant-voice menu bar app,
            browser tab, headless audio sink
```

Two containers on a shared Docker network: the main `voice-server` (Bun, ports 8888 local + 8889 HTTPS public) and `voice-server-kokoro` (Python, port 7880 internal). The main container reaches the sidecar by container name.

## What it exposes

A small HTTP/WebSocket API on two ports.

```
HTTP (port 8888, internal)
GET  /health      -> server status, provider info, connected client count
POST /notify      -> generate speech and broadcast to WebSocket clients
WSS  /stream      -> WebSocket subscription for audio (binary frames)

HTTPS (port 8889, public)
GET  /health      -> same as above
WSS  /stream      -> same as above, with TLS
```

`POST /notify` accepts:

```json
{
  "title": "Assistant",
  "message": "The deployment finished cleanly.",
  "voice_enabled": true,
  "voice_name": "bf_emma",
  "priority": "normal"
}
```

Only `message` is required. `voice_name` is an optional per-request override (must match the active provider's voice format). `voice_enabled: false` skips audio generation entirely — useful if you want a notification log entry without actually playing anything.

When a client connects to `/stream`, it first receives a JSON greeting (`{"type":"connected","clients":N}`). For each notification, clients receive two sequential WebSocket messages: a JSON metadata frame (`{"type":"notification","title":"...","message":"...","size":12345}`) followed by a binary frame containing the raw MP3 bytes.

## Tech stack

| Component | Choice | Why |
|-----------|--------|-----|
| Front-end runtime | Bun + TypeScript | Bun's WebSocket server is fast, low-ceremony, and ships with built-in TLS. No Express, no separate ws library. |
| TTS sidecar | Python + Kokoro | The Kokoro project's API is Python-native; spawning a sidecar keeps the front end small and lets you scale them independently. |
| Local model | Kokoro v1.0 | Apache 2.0, ~82M parameters, runs on CPU, multiple voices and languages. Best free local TTS I've tried. |
| Audio encoding | ffmpeg (in the sidecar) | Standard MP3 at 128 kbps. Browsers and AVFoundation both decode it without complaint. |
| Hosted providers | ElevenLabs, Google Cloud TTS | Optional — used when you want better quality than the local model. |
| Containers | Docker Compose | Two services on a shared network. The sidecar isn't exposed externally; only the main server is. |
| TLS | PEM certs read from disk | The HTTPS listener loads `fullchain.pem` and `privkey.pem` at startup. If they're not present, the HTTPS port simply doesn't open. |
| Heartbeat | Built-in WebSocket ping/pong | Server pings every 30s, removes clients that don't pong within 90s. |

## Key decisions

**Why a server instead of having the assistant call TTS directly?**
Three reasons. First, broadcast — multiple clients on multiple machines can all play the same audio simultaneously, which a direct integration can't do. Second, provider abstraction — swapping TTS engines is a server-side change with zero client work. Third, sanitization — the assistant occasionally produces text with control characters, shell metacharacters, or markdown that confuses TTS. Centralizing the cleanup means each client gets clean audio with no per-client logic.

**Why split the Bun front end and the Python sidecar?**
Kokoro's Python API is the path of least resistance for the local model — there's no Bun-native binding and the model itself is PyTorch. But Python's HTTP and WebSocket story is heavier than Bun's, and most of this server's work is HTTP/WS plumbing, not inference. Splitting them means the front end is small, fast, and easy to reason about, while the sidecar can be restarted, swapped, or scaled independently. They communicate over plain HTTP on a Docker network — the latency cost is negligible compared to TTS generation time.

**Why Kokoro as the default local model?**
It's the only widely-deployed open-source TTS that's good enough to use for daily notifications. Others sound robotic or need a GPU bigger than I want to dedicate. Kokoro v1.0 runs in CPU mode in about a second per short phrase, the voices are pleasant, and it's Apache 2.0 with no per-call cost. The known NaN bug (the model occasionally produces NaN values in the audio buffer) is handled with auto-recovery — the sidecar reloads the pipeline and retries once if it sees NaN.

**Why a "tiered" provider system with automatic fallback?**
The assistant produces a steady trickle of voice events. If a provider fails (rate limit, network blip, model crash), the next event should still play, ideally seamlessly. The tiered system tries the primary provider first, catches the failure, logs the reason, and falls back to Kokoro. Kokoro is the bottom of the chain because it's local and effectively never fails — the worst case is a one-time NaN that recovers on retry.

**Why two ports — HTTP local and HTTPS public?**
Local clients (browser pages, headless sinks running on the same network) don't need TLS. Adding it makes them harder to develop against. Remote clients (the Mac menu bar app, anything reached over a VPN) need wss:// to work in a real browser context. Running both listeners means each kind of client uses the protocol that fits, without a reverse proxy.

**Why broadcast to all clients instead of routing?**
Routing would mean tracking which client wants which messages, building some addressing scheme, and managing client identity. The current usage doesn't need it — every connected client wants every notification, the way every device on the network can hear a real-world speaker. If a future use case wants targeted notifications, a `target_client` field on `/notify` plus client-side filtering would handle it without restructuring the broadcast loop.

**Why backpressure detection on every send?**
Bun's `client.send()` returns the byte count on success, 0 if the send was dropped due to backpressure, or a negative number if the socket is dead. Without checking that, dead sockets accumulate silently and the broadcast loop wastes work. The server checks the return value and closes any client whose send failed — that forces a clean reconnect from the client side, which the menu bar app handles automatically.

## How it works

### Request lifecycle

1. POST arrives at `/notify` with a JSON message and optional voice override
2. The text is sanitized (markdown stripped, shell metacharacters removed, truncated to 500 characters)
3. The active provider is determined by `TTS_PRIMARY` env var (`chatterbox`, `kokoro`, etc.)
4. The provider router calls the appropriate `generateSpeech*` function
5. On primary failure, the router falls back to Kokoro (last resort)
6. The MP3 buffer is broadcast to every connected WebSocket client as a binary frame, preceded by a JSON metadata frame
7. The HTTP response returns immediately with `{"status":"success"}`

### The Kokoro sidecar

A small Python HTTP server wraps the `KPipeline` API:

- `POST /tts` accepts `{"text": "...", "voice": "bf_emma"}` and returns `audio/mpeg` bytes
- `GET /health` returns model status and a count of NaN auto-recoveries

The first generation on a new pipeline can produce NaN values (a known upstream issue). The sidecar handles this two ways:

1. **Warmup at load**: Each language pipeline is created with a one-off "warmup" pass using a matching voice. This burns the first NaN-prone generation on a throwaway request.
2. **NaN auto-recovery**: After every real generation, the sidecar checks the audio buffer for NaN. If detected, it reloads the pipeline and retries once. If NaN persists, it returns 500 — but that hasn't happened in practice.

Multiple language pipelines are loaded lazily. The voice name's two-letter prefix (`af_`, `bm_`, `jf_`, etc.) tells the sidecar which `KPipeline` to use.

### Provider routing

The provider router in the front end is a 30-line function: try the primary, catch failure, fall back to Kokoro. Each provider has its own `generateSpeech*` function that takes text and returns an `ArrayBuffer` of MP3 bytes. Adding a new provider is a matter of writing one such function and adding a case to the router.

### WebSocket broadcasting

When a notification fires, the server iterates over the set of connected clients and sends each one the metadata frame followed by the audio frame. Bun's `send()` is synchronous, so both sends complete atomically within the same microtask — clients always see the metadata immediately before the audio.

The set of clients is maintained by the WebSocket lifecycle handlers (`open`, `close`, `error`). A periodic timer checks for clients that haven't responded to a ping in 90 seconds and closes them.

### Configuration

Everything is controlled by environment variables, read at startup from a `.env` file mounted into the container. Changing voices or providers requires a `docker restart` — the server doesn't hot-reload config because the cost of restart is one second and the simplicity of "no hot-reload code" is worth it.

## Deployment

1. Copy the reference code into a folder on your server
2. Install Docker and Docker Compose if you don't have them
3. Create a `.env` file with the variables you need (see `reference-code/README.md` for the list). At minimum: `TTS_PRIMARY`, the relevant voice and URL for whichever provider you pick, and (for the HTTPS listener) paths to your TLS cert and key
4. If you want HTTPS, drop your TLS certificate at the path the server expects (`fullchain.pem` and `privkey.pem` in the certs directory). The server is HTTP-only if certs are missing, so you can skip this for local-only setups
5. Create the shared Docker network: `docker network create voice-net` (or whatever name you used in `docker-compose.yml`)
6. `docker compose up -d --build` builds and starts both containers
7. Test with `curl -X POST http://localhost:8888/notify -H 'content-type: application/json' -d '{"message":"hello"}'` — you should see a 200 response and any connected WebSocket client should play the audio

To use it from the Mac menu bar app, build the [assistant-voice](../assistant-voice/) app pointing at this server's `wss://your-host:8889/stream` URL.

## Reference code

The `reference-code/` folder has working source files from my install. Sanitized to remove my server hostnames and paths. They aren't production-hardened code; they're a reference for how one version of this looks. Use them to understand the patterns, then adapt for your own setup.

See [`reference-code/README.md`](./reference-code/README.md) for a file-by-file breakdown.

## Things to watch out for

- **The Kokoro NaN bug is real but handled.** If you see `NaN detected, reloading pipeline` in the sidecar logs, the auto-recovery is working as designed. If you see it constantly, something's wrong with the Kokoro install (model file path, voice file path, or torch version mismatch).
- **The `kokoro-tts-cpu:local` base image has to be built separately.** The Kokoro project has Docker setup steps. Don't expect `docker compose up` to pull this image from a registry — it's a local image you build once.
- **TLS certs are loaded at startup, not hot-reloaded.** If you renew certs (Let's Encrypt every 90 days), restart the container. Otherwise the server keeps using the old cert until it expires.
- **The server uses `0.0.0.0` for both listeners.** Inside a Docker container with port mapping that's fine, but if you ever run this outside Docker, bind to `127.0.0.1` and put a reverse proxy in front, or you'll expose the server to the whole network without TLS.
- **`TTS_PRIMARY=kokoro` skips the Chatterbox attempt entirely.** If you don't have Chatterbox running and don't change this var, every notification will log a connection-refused failure before falling back to Kokoro. Set `TTS_PRIMARY=kokoro` (or whatever you actually have) explicitly.
- **The 500-character truncation in `sanitizeForSpeech` is a hard cap.** If your assistant produces longer messages, they'll be cut off mid-sentence. Either increase the cap or have the assistant produce shorter voice lines.
- **Voice name format is provider-specific.** Kokoro uses `[lang][gender]_[name]` (e.g., `bf_emma`). ElevenLabs uses opaque IDs. Google uses dotted names. The server doesn't translate between formats — pick a voice that matches your active provider.

## What you could do differently

- **Use OpenAI TTS** as another provider if you want hosted TTS without ElevenLabs. The OpenAI API is simpler and cheaper than ElevenLabs for most use cases. Adding it is a single new `generateSpeech*` function in the front end.
- **Run inference on GPU** if you have one. Kokoro is dramatically faster on GPU. The sidecar Dockerfile would need a CUDA base image and a small change to the model load call.
- **Drop the sidecar entirely** and run a hosted TTS as the only option. If you don't care about local generation, you can collapse this to a single Bun container that just calls a hosted API. About 100 lines.
- **Add per-client filtering** if you want to broadcast different audio to different clients. A `target` field on `/notify` plus client-side filtering on the WebSocket would do it. Most setups don't need this.
- **Cache common phrases.** If the assistant says the same boilerplate ("Done.", "On it.", etc.) often, hashing the text and caching the MP3 in memory avoids redundant TTS calls.
- **Add WebRTC for lower latency** if you ever care about sub-second voice latency. For notifications this is overkill; for a real conversational interface it would matter.
- **Authenticate the broadcast endpoint.** Right now `/notify` is open — anyone who can reach the port can play arbitrary audio on every connected client. For a private network this is fine; if you're exposing the port publicly, add a bearer token or HMAC check.
