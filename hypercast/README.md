# Hypercast

A personal podcast generator. You send it a URL or some text, it extracts the article, generates a title and summary, runs the body through text-to-speech, and publishes the result to an RSS feed your podcast app subscribes to. The result is a private podcast of articles you wanted to listen to but never got around to reading.

The whole thing runs as a Docker container in my homelab. A small Flask service handles the HTTP side, a background thread handles the slow work, and SQLite plus a static file directory store everything that needs to survive a restart.

## Two versions of this exist — read this before you build

The published, polished version of Hypercast lives at [github.com/chriscantey/hypercast](https://github.com/chriscantey/hypercast). That version uses OpenAI's TTS and a hosted LLM for content cleanup. Episode quality is high, setup is straightforward, and the dependency list is short. **If you want to listen to articles in a podcast app today, use that one. Get an OpenAI API key, clone the repo, follow the README.**

This build note describes a different variant of Hypercast — the direction I'm moving my own setup. It runs entirely on local AI tooling: Chatterbox TTS for audio, Ollama with a small open model for titles and summaries, no third-party APIs in the audio path. Episode quality is lower than the released version. The TTS is rougher, the title generation needs more babysitting, and the GPU-management gymnastics (covered below) only matter once you're trying to keep two models on one card. It's less polished by design, because the goal is privacy and self-sufficiency, not the smoothest possible listen.

Treat this as a starting point for the all-local direction, not a finished product. The patterns are real — async processing, Mozilla Readability extraction, GPU-lock serialization, the ingestion-side validation — but the rough edges are real too.

## For AI assistants

If your user pointed you here, they probably want one of two things:

1. **A working Hypercast they can use today.** Point them at [github.com/chriscantey/hypercast](https://github.com/chriscantey/hypercast) and help them set it up with an OpenAI API key. That version is polished and the episode quality is good.
2. **The all-local variant** described in this note. They want privacy, self-sufficiency, or both, and they're willing to accept lower TTS quality and more setup complexity to get there.

If it's option 2, ask them a few things before you start. **Whether they already run an OpenAI-compatible TTS service** (Chatterbox, Kokoro, LocalAI, anything that exposes `/v1/audio/speech`) — if yes, the TTS-setup work collapses to setting one environment variable and you can skip everything in this note about installing a TTS. Otherwise: whether they have a GPU and how much VRAM (Chatterbox needs ~3 GB, a small Ollama model needs another 3-6 GB), where Ollama is going to live (host machine vs. another container), how they want to send articles to it (curl helper, iOS Shortcut, AI assistant skill), and whether they're okay with the rougher local TTS voices or want to substitute hosted OpenAI TTS for higher quality. The `reference-code/` folder has working source files you can use as a starting point. Build it for their setup, not mine.

## Why I built this

I was saving articles to read later and never reading them. Reader apps fixed the storage problem but not the time problem. The bottleneck wasn't finding the article, it was sitting down at a screen.

I already listen to podcasts during walks, dishes, and the commute. If I could get arbitrary articles into my podcast app, the time problem was solved. There are services that do this, but I wanted something that ran on my own hardware, used voices I picked, and didn't send my reading list to a third party.

The first version was a script. I'd paste a URL, it would shell out to OpenAI's TTS, and write an MP3. That worked but I had to be at my computer to use it. The next version, the one currently published at [github.com/chriscantey/hypercast](https://github.com/chriscantey/hypercast), turned that into an HTTP service with an RSS feed using OpenAI for both text cleanup and audio. I've been using it daily for a long time and the episode quality is good.

This local-AI variant is where I'm taking my own copy. The motivation is the same shape that drives a lot of self-hosting: I'd rather not send every article I read to a third party for processing, the API costs add up, and once you've got a GPU sitting in a homelab it feels wasteful to leave it idle while you pay per token. So this version swaps OpenAI's hosted TTS for Chatterbox running locally, and a hosted LLM for Ollama. The trade-off is honest — episode quality is lower and the setup is more involved — but the whole pipeline runs on hardware I own.

## How the assistant uses it

There's a small skill in my AI assistant setup that knows two things: the local API endpoint and the API key. When I say "send this article to Hypercast" or paste a URL with a similar phrase, the assistant does a single POST to `/create` with the URL in the body and confirms the request was accepted. That's the entire skill.

The service does everything else. Content extraction, title generation, text-to-speech, audio assembly, database write, RSS update. The assistant doesn't need to know how any of that works. It just hands off the URL and walks away. From the assistant's side, Hypercast looks like a fire-and-forget endpoint that takes a URL and returns 202.

This boundary matters. I didn't want the assistant orchestrating the pipeline because it would have to know about TTS providers, voice configuration, and audio paths. Putting that intelligence in the service means I can also send articles from an iOS Shortcut or a browser bookmarklet without rebuilding the integration each time.

## Architecture

```
Client (assistant skill, iOS Shortcut, curl)
    |
    |  POST /create  { "input": "https://example.com/article" }
    v
Flask + gunicorn (1 worker, daemon threads)
    |
    +-- validate_input()         URL detection, fetch, size checks
    +-- 202 Accepted             Returns immediately
    |
    [Background thread, GPU lock held]
    |
    +-- Mozilla Readability      Bun subprocess, Firefox-grade extraction
    +-- BeautifulSoup fallback   4-stage deterministic cleanup
    +-- Ollama (qwen3:8b)        Title + summary via native API
    +-- Chatterbox TTS           ~500-word segments, intro sound prepend
    +-- pydub + ffmpeg           Audio assembly to MP3
    +-- SQLite write             Episode metadata
    |
    v
RSS feed at /feed  +  MP3 files at /static/audio/
    |
    v
Podcast app polls feed, downloads new episodes
```

The HTTP request returns in milliseconds. The actual work happens in a daemon thread. A long article (6000+ words) can take 30-45 minutes to TTS. The client doesn't wait. The episode shows up in the podcast app whenever the next feed poll happens.

## What it exposes

A small HTTP API, all under a single port:

```
GET  /                  Web UI for browsing recent episodes
GET  /create            Form for submitting a URL or text from the browser
POST /create            JSON endpoint for programmatic submission (X-API-Key required)
GET  /feed              RSS feed (iTunes-compatible, served to podcast apps)
GET  /static/audio/...  The MP3 files
GET  /static/images/... Cover art and intro sound
```

`POST /create` accepts:

```json
{
  "input": "https://example.com/article or raw text",
  "url": "optional explicit URL to fetch instead of input",
  "voice": "optional voice override for this episode"
}
```

`input` is required. If it's a URL, the service fetches and extracts the article. If it's raw text, the service uses it directly. If it's short text containing an embedded URL (common with iOS Shortcuts that send the page title plus the link), the service detects the URL and fetches it.

`url` is an explicit override that takes priority over `input` for fetching. Useful when a Shortcut sends the extracted page text in `input` but you want the source URL fetched fresh.

`voice` is an optional per-request override. Without it, the service uses the configured default voice from the environment.

## Tech stack

| Component | Choice | Why |
|-----------|--------|-----|
| Web framework | Flask + gunicorn | Small surface area, well-understood, one worker is plenty for a single user. |
| Article extraction | Mozilla Readability via Bun subprocess | The same extractor Firefox Reader View uses. The Python ports are weaker. Bun is small and fast enough that subprocess overhead is negligible. |
| Fallback extraction | BeautifulSoup with regex cleanup | Deterministic, free, no LLM needed for most pages. Four-stage extraction handles the long tail. |
| LLM (title and summary) | Ollama with qwen3:8b | Local, no API cost, no rate limits, and good enough for short generative tasks. Native Ollama API (not OpenAI-compatible) so we can pass `think: false`. |
| TTS | Chatterbox via OpenAI-compatible endpoint | Self-hosted, multiple voices via WAV files, talks the OpenAI speech protocol so the existing OpenAI Python client works unchanged. |
| Audio assembly | pydub + ffmpeg | Concatenate segments, prepend intro sound, export MP3. Simple. |
| Storage | SQLite (episode metadata) + filesystem (MP3) | Trivial backup, fits the data shape, no migration overhead. |
| RSS feed | xml.etree.ElementTree | Standard library, iTunes namespace is just a few extra elements. |
| Auth | X-API-Key header with `hmac.compare_digest` | One key, one user, no rotation needed. Constant-time comparison prevents timing attacks. |
| Deployment | Docker Compose, restart policy `unless-stopped` | One container, one network, mounted volumes for audio, images, data. |

## Key decisions

**Why fully async with 202 Accepted instead of streaming or synchronous?**
A long article can take half an hour to TTS. A synchronous response would either time out or hold an HTTP connection open for thirty minutes. Streaming would complicate every client. Fire-and-forget plus an RSS feed is the natural shape for podcast distribution. The client posts and forgets. The episode shows up when it shows up. Podcast apps already poll, so there's no need to notify anyone.

**Why Mozilla Readability via a Bun subprocess instead of a pure Python extractor?**
Article extraction is a deceptively hard problem. Real-world pages are full of navigation, ads, popups, share widgets, related-content rails, and content management system noise. Mozilla Readability is the extractor Firefox Reader View uses, and it has been refined against millions of pages over a decade. The Python ports lag behind. Shelling out to a thirty-line Bun script that calls the official Readability library gives me the gold standard with a 30-second timeout and clean JSON output. The subprocess overhead is in the noise next to a thirty-minute TTS run.

**Why deterministic extraction with optional LLM cleanup, instead of LLM cleanup as the default?**
LLM cleanup costs money, takes time, and can hallucinate text that wasn't in the original article. The deterministic pipeline (Readability primary, BeautifulSoup with a long deny-list of boilerplate patterns as backstop) handles most pages cleanly. The LLM cleanup pass is opt-in via `CONTENT_CLEANUP_LLM=true` for the rare stubborn page. There's even a guard that rejects LLM output if it's grown more than 20% from the input, on the theory that the model is probably hallucinating rather than cleaning.

**Why the native Ollama API instead of the OpenAI-compatible endpoint?**
Qwen3 has a "thinking mode" that emits `<think>...</think>` blocks before its actual answer. Through Ollama's OpenAI-compatible `/v1/` endpoint those tokens leak through and end up in the title or summary. The native `/api/chat` endpoint accepts a `think: false` option that suppresses thinking entirely. Native API costs me one extra HTTP client wrapper. The trade-off is worth it.

**Why a single GPU lock that serializes episode processing?**
Ollama (qwen3:8b at ~5.6 GB VRAM) and Chatterbox TTS (~3 GB VRAM) share the same GPU. They don't run at the same time within a single episode, but two concurrent episodes would have both models active and would OOM the card. A `threading.Lock()` around the background processor serializes everything. A second request gets a 202 immediately and queues up behind the lock. Total throughput is the same since the GPU was the bottleneck either way, and there are no failure modes from contention.

**Why split text into ~500-word TTS segments instead of one giant TTS call?**
Three reasons. Visibility, recoverability, and timeout headroom. With segments I get per-segment progress logs, so if an episode is taking 30 minutes I can see which segment it's on. If a segment fails (rare but it happens), the others survive. And the per-call timeout is much shorter than for a 6000-word monolith, so transient network blips don't cost the whole episode. The segment boundary is a paragraph boundary when possible, so the audio still has natural pauses.

**Why a separate API service instead of having the assistant call Chatterbox directly?**
Decoupling. The assistant doesn't need to know about Readability, Ollama, intro sounds, or RSS generation. It just knows the URL and the API key. The same endpoint serves an iOS Shortcut, a browser bookmarklet, and an AI assistant skill. If I swap TTS providers, change the LLM, or add a new processing stage, none of the clients change. Putting the pipeline behind one POST endpoint also means I can add request logging, rate limiting, or queueing in one place.

**Why SQLite for episode metadata instead of writing the RSS feed to a file directly?**
The feed is regenerated from the database on every `/feed` request. That sounds wasteful but it isn't — episodes are small, the database is one file, and SQLite handles concurrent reads fine for one user. The advantage is that the source of truth is structured and queryable. I can build admin tools, regenerate the feed, or migrate to a different feed format without touching the audio files.

## How it works

### Request lifecycle

A POST to `/create` does three things in sequence:

1. **Validate the input.** Check size, decide whether it's a URL or text, and if it's a URL, fetch and extract immediately. The `validate_input()` function returns a Readability article dict (for URLs) or a plain string (for text). This happens synchronously so the client gets a meaningful 400 if the input is bad.
2. **Spawn a background thread.** The thread acquires the GPU lock, calls `process_validated_input()` to generate the title and summary, then `create_episode()` to do the TTS and audio assembly. The lock keeps multiple requests from competing for the GPU.
3. **Return 202 Accepted.** This happens immediately, before any of the slow work. The client knows the request was accepted but not that the episode is ready.

### Content extraction pipeline

The extraction pipeline tries the highest-quality option first, then falls back:

1. **Mozilla Readability** (primary). HTML goes in via stdin to a Bun subprocess running the official `@mozilla/readability` package. Returns title, byline, text content, excerpt. If the extracted text is under 100 characters, treat as a failure.
2. **BeautifulSoup** (fallback when Readability is bypassed). Four stages: tag removal (script, style, nav, footer, etc.), class/id/role pattern matching against a long deny-list of boilerplate alternations, content region detection (article > main > role=main > content-class divs > body), and post-extraction line cleanup with another set of patterns for residual boilerplate.
3. **LLM cleanup** (opt-in, off by default). If `CONTENT_CLEANUP_LLM=true`, send the extracted text to the configured provider with a tight system prompt asking only for boilerplate removal. Reject the result if it inflated more than 20%, on the theory that the model is hallucinating.

### Title and summary generation

After extraction, the service generates a podcast-style title and 2-3 sentence description. Title uses the Readability-extracted page title if available; otherwise the first 300 characters get sent to the LLM. Summary uses the first 1000 characters. Both are kept short to fit the iTunes feed format.

The LLM provider is configurable: Ollama (default), OpenAI, or Gemini. Ollama is a good answer for anyone with a GPU — qwen3:8b runs in around 5.6 GB of VRAM, costs nothing per call, and the title and summary it produces are good enough that I haven't been tempted to switch back.

### TTS and audio assembly

`create_episode()`:

1. Strips markdown syntax from the text (headings, lists, links, code, blockquote markers) while preserving sentence structure so the TTS produces natural pauses at section breaks.
2. Splits the text into ~500-word segments on paragraph boundaries.
3. Sends each segment to the OpenAI-compatible TTS endpoint with progress logging.
4. Combines all segments with the intro sound at the start using pydub.
5. Exports a single MP3 at 192k bitrate.
6. Writes the metadata row to SQLite, including a duration calculated from the file.

The audio file lands in `/app/app/static/audio/` inside the container, which is volume-mounted to a host directory. The RSS feed serves URLs that point at `/static/audio/{filename}` so the podcast app can pull the file directly.

### TTS providers

Hypercast doesn't care which TTS service you use, as long as it speaks the OpenAI `/v1/audio/speech` protocol. Configuration is two environment variables: `OPENAI_BASE_URL` (where to send the request) and `TTS_VOICE` (which voice name to use). Everything that isn't TTS — extraction, title, summary, audio assembly, RSS — is identical regardless of which TTS sits behind that URL.

Four setups cover almost everyone:

**Already running an OpenAI-compatible TTS.** If you already have Chatterbox, Kokoro, LocalAI, or another service exposing `/v1/audio/speech` somewhere on your network, the TTS work is done. Set `OPENAI_BASE_URL` to its `/v1` endpoint (`http://localhost:8890/v1` for a host-local Chatterbox, `http://chatterbox-tts:8890/v1` for one on a shared Docker network with Hypercast). Most services list available voices at `/v1/voices` (e.g., `curl -s http://localhost:8890/v1/voices | jq`). Set `TTS_VOICE` to one you like and you're done.

**Start fresh with Chatterbox** (local, GPU, multi-voice, best local quality). Around 3 GB of VRAM. Run it as a Docker sidecar on the same network as Hypercast. Voices are `.wav` files in the Chatterbox `voices/` directory; the value of `TTS_VOICE` maps to `<name>.wav`. The Chatterbox repo has Docker setup steps. Sample voices ship with the image.

**Start fresh with Kokoro** (local, CPU-only, no GPU needed, Apache 2.0). An 82M-parameter open-source model with multiple voices across several languages. Use this if you don't have a GPU or want to keep VRAM free for something else. The Kokoro repo ships a Docker image that exposes the OpenAI-compatible interface; point `OPENAI_BASE_URL` at it and set `TTS_VOICE` to a Kokoro voice name (the project README has the current voice catalog; `af_heart` is a common default).

**Hosted OpenAI TTS** (cloud, no infra to run). Set `OPENAI_BASE_URL=https://api.openai.com/v1`, set `OPENAI_API_KEY` to your real key, and set `TTS_VOICE` to one of OpenAI's voice names (`alloy`, `nova`, `shimmer`, and several others — see the OpenAI TTS docs for the current list). Best quality of the four options. The trade-off is the per-character cost and that your articles get processed by a third party. This is what the [released version of Hypercast](https://github.com/chriscantey/hypercast) ships with by default.

### RSS feed

The feed is generated on every request from the database. Standard RSS 2.0 with the iTunes namespace for `itunes:image` and `itunes:duration`. The base URL is configurable via `BASE_URL` so the feed works whether the service is reached on the LAN, through a reverse proxy, or over a VPN.

## Deployment

1. Get the service code into a folder (`./hypercast/` works).
2. Create `.env` from the example with these values: `API_KEY` (random hex string from `openssl rand -hex 32`), `BASE_URL` (the URL your podcast app uses to reach the service), TTS provider config, and content provider config.
3. Point `OPENAI_BASE_URL` at your TTS service's `/v1` endpoint and `TTS_VOICE` at the voice you want. See [TTS providers](#tts-providers) above for the four setup paths (already-running, Chatterbox, Kokoro, hosted OpenAI). If your TTS runs in a separate container, make sure it's on a shared Docker network with Hypercast, or reachable via `host.docker.internal:host-gateway` if it's on the host.
4. `docker compose up -d --build`
5. Visit `http://your-host:4973` to confirm the web UI loads.
6. POST a test URL to `/create` with the API key in the `X-API-Key` header. You should get `{"status": "processing"}` back immediately and an episode in the feed a few minutes later.
7. Add the feed URL (`http://your-host:4973/feed`) to your podcast app.

For HTTPS, run it behind a reverse proxy (nginx, Caddy, Traefik). The container itself speaks plain HTTP on the configured port.

## Reference code

The `reference-code/` folder has working source files from the running system. These are real files, sanitized to remove hostnames and secrets, included as reference for how one version of this looks. They aren't production-hardened and shouldn't be deployed to the public internet as-is. Use them to understand the patterns, then adapt for your own setup.

See [`reference-code/README.md`](./reference-code/README.md) for a file-by-file breakdown.

## Things to watch out for

- **This is single-user, local-network software.** The auth model is one shared API key in a header. There's no per-user separation, no rate limiting, and no abuse mitigation. Don't put it on the public internet. Use it on your LAN, over Tailscale, or behind a VPN.
- **GPU contention is real if you don't serialize.** The first version had no lock and would happily start two TTS jobs at once, OOM the GPU, and crash the Chatterbox container. The lock was a one-line fix that made everything reliable.
- **Qwen3's thinking mode leaks through Ollama's OpenAI-compatible endpoint.** If you use `/v1/chat/completions` for title generation, you'll get `<think>...</think>` blocks in your titles. Use the native `/api/chat` endpoint with `think: false`.
- **Long articles take a long time.** A 6000-word piece is 30-45 minutes of TTS. The default OpenAI Python client timeout is 10 minutes, which isn't enough — the code overrides it to 60 minutes. If you swap clients, watch for this.
- **iOS Shortcuts often send page text plus URL together.** The validator detects an embedded URL in short text inputs (under 500 characters) and refetches it fresh, because the Shortcut-extracted text is usually missing chunks. If your client always sends clean content, you can disable this.
- **Audio paths inside the container are relative.** The Flask app expects to find `/app/app/static/audio` and `/app/data` for the SQLite database. The volume mounts in `docker-compose.yml` provide these. Forget the mount and the database resets on every container rebuild.
- **The RSS feed regenerates from the database every time.** That's fine for hundreds of episodes. If you ever get into the thousands, cache the feed for a minute or two — the database read is fast but the XML serialization adds up.

## What you could do differently

- **Use Kokoro instead of Chatterbox for TTS** if you want something open-source and CPU-friendly. Quality is competitive, no GPU needed, and the Docker setup is similar.
- **Use OpenAI or Gemini TTS** if quality matters more than running locally. Both produce natural voices without the local model overhead. The trade-off is a per-character cost and your articles get sent to a third party.
- **Skip Mozilla Readability** and use BeautifulSoup alone if subprocess overhead bothers you. You'll handle 80% of pages cleanly and the rest will need manual text submission. The trade-off is fewer dependencies vs. better extraction quality.
- **Run a worker queue** (RQ, Celery, even just a list of pending jobs in SQLite) instead of daemon threads. The thread approach works for one user. If you ever want retries, scheduling, priority, or visibility into a queue, a real worker beats threads.
- **Add per-user separation** if more than one person uses the service. Right now everyone shares one feed, one voice config, and one episode list. A small `users` table and per-user feed URLs would handle this without much restructuring.
- **Generate chapter markers** for long articles by inserting silence at section boundaries and exposing the offsets via the RSS `psc:chapters` extension. Some podcast apps support this and it makes longer episodes much more navigable.
- **Cache the RSS feed for a minute or two** if you ever scale past a few hundred episodes. The database read is fast but the XML serialization adds up.
- **Stream the TTS output** instead of writing per-segment files and concatenating. The complexity goes up but the temp file dance goes away. Worth it if disk I/O ever becomes a bottleneck.
