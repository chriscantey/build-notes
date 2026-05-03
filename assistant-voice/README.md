# Assistant Voice

A Mac menu bar app that connects to a personal AI voice server over WebSocket and plays back any audio the server pushes to it. The server handles text-to-speech and broadcasts MP3 chunks; this app is the speaker that always answers.

The whole thing is a single Swift file with no third-party dependencies. It runs in the menu bar, never opens a window, and stays connected as long as you're on a network it trusts.

## For AI assistants

If your user pointed you here, they're probably asking you to help them build a voice output that doesn't quit on them when they switch apps or close the browser. Read through this note with them and ask a few things before you start: where their voice server lives (or whether they even have one yet — if not, the server is a separate build), how it broadcasts audio (WebSocket binary frames is the assumption here, but server-sent events or HTTP push would work too with small changes), which networks should auto-reconnect (usually home LAN plus a VPN range like Tailscale's CGNAT), and whether they want a single hardcoded server or a switcher in the menu. The `reference-code/` folder has the working source. Build it for their setup, not mine.

## Why I built this

I used to run my assistant's voice through a browser tab. The server would push audio via WebSocket and a small page would play it. That worked great for about ten seconds at a time, until the moment I switched to a different tab or the browser fell behind another window.

Browsers throttle backgrounded tabs. JavaScript timers slow down, audio decoding pauses, and the connection sometimes drops entirely. The result was that voice notifications would just silently stop arriving the moment I wasn't looking at the tab. Worse, the failure was invisible — the tab still looked "connected." I'd be in the middle of working, expect to hear something, and get nothing.

I wanted a voice channel that behaved like the rest of my system. Always on, always responsive, no foreground requirement. A native menu bar app fixes this completely. macOS doesn't throttle menu bar apps. The WebSocket stays open, audio plays the instant it arrives, and the icon in the menu bar tells me at a glance whether things are working.

The other thing I wanted was for the app to be smart about networks. I move the laptop between home, the office, coffee shops, and the occasional plane. I don't want it pounding a server it can't reach. So the app only auto-reconnects when it sees one of a small list of allowed networks (home LAN, Tailscale). On any other network it goes quiet and waits — no log spam, no battery drain.

## How the assistant uses it

The assistant doesn't talk to this app directly. It talks to the voice server, which talks to this app. The pipeline looks like: the assistant calls a `/notify` endpoint on the server with a message, the server calls a TTS provider (Kokoro locally, or ElevenLabs/Google in the cloud), the server gets back an MP3, and the server broadcasts that MP3 over WebSocket to every connected client. This app is one of those clients.

The server side is documented in the [voice-server](../voice-server/) build note — read both together if you're standing up the full pipeline. The two are designed as a pair: this app is the receiver, the voice server is the broadcaster.

That separation matters. The assistant's intelligence lives on the server side. This app is dumb on purpose — it's a speaker. If you have multiple Macs, you run a copy on each one and they all play the same audio in sync (or close enough; there's no clock-tight synchronization). If you swap TTS providers or add a new one, this app doesn't change.

## Architecture

```
+------------------+     POST /notify     +------------------+
|  AI Assistant    | -------------------> |  Voice Server    |
|  (anywhere)      |                      |  (Linux box)     |
+------------------+                      +--------+---------+
                                                   |
                                       TTS API call (ElevenLabs/Google)
                                                   |
                                                   v
                                          MP3 audio response
                                                   |
                                                   |  WebSocket
                                                   |  (binary frame)
                                                   v
                                         +-------------------+
                                         |  Assistant Voice  |
                                         |  (macOS menu bar) |
                                         +-------------------+
```

The voice server is responsible for everything semantic. This app is a streaming audio sink with a status icon.

## Tech stack

| Component | Choice | Why |
|-----------|--------|-----|
| Language | Swift | Native macOS access to AVFoundation, Network, Cocoa with no bridging |
| UI | NSStatusItem + NSMenu | Menu bar only, no dock icon, no window |
| WebSocket | URLSessionWebSocketTask | Built into Foundation, supports text + binary frames |
| Audio | AVAudioPlayer | Plays MP3 data directly from memory, no temp files |
| Network detection | NWPathMonitor + getifaddrs | Detects interface changes; CIDR-matches the local IP |
| Build | Swift Package Manager | `swift build -c release`, no Xcode project |
| Bundling | Hand-rolled Makefile | Wraps the binary in a `.app` bundle, generates `Info.plist`, ad-hoc signs |
| Process management | None — user launches it | Lives in `/Applications`, opens at login if you add it manually |

No external dependencies. Everything ships with macOS. The whole app is one Swift file, around 600 lines.

## Key decisions

**Why a native menu bar app instead of a browser tab or Electron?**
Browsers throttle backgrounded tabs. That's the whole reason this app exists. Electron would dodge the throttling but adds a 100+ MB runtime for what is essentially "play this MP3 when it arrives." A native menu bar app is the smallest possible thing that solves the problem. Cocoa's menu bar APIs are stable, the binary is under 1 MB, and it doesn't show up in Cmd-Tab.

**Why a single Swift file with no dependencies?**
The app does three things — connect a WebSocket, play audio, change a menu bar icon. Each of those has a clean Apple-provided API. Pulling in even one third-party package would multiply the build complexity (Xcode project files, dependency lockfiles, code signing implications) without saving meaningful code. The whole app fits in 600 lines and reviews quickly.

**Why subnet-aware reconnection instead of always trying to reconnect?**
The early version reconnected unconditionally. When I'd take the laptop somewhere else, it would burn battery and fill logs trying to reach a server it had no path to. Now it checks the local interfaces against a small list of allowed CIDR blocks (home LAN, Tailscale CGNAT range). If the IP doesn't match, it goes silent and waits. NWPathMonitor wakes it back up the moment the interface changes, so the moment Tailscale comes up or the home WiFi is detected, it reconnects within seconds.

**Why a heartbeat ping every 15 seconds?**
TCP connections die silently. The "Connected" status meant nothing if the underlying socket had been dead for an hour after a sleep/wake cycle or a network blip. The fix was a 15-second client ping with a 10-second pong timeout. If the pong doesn't come back, the app treats the connection as dead and reconnects. The server pings back from its side too, so either end can detect the rot. This was the single biggest reliability improvement.

**Why exponential backoff capped at 60 seconds?**
A short-lived server outage shouldn't cause a 5-minute reconnect delay. A long outage shouldn't cause every-3-seconds hammering. Exponential backoff (3, 6, 12, 24, 48, 60) splits the difference and resets to 3 seconds the instant a connection succeeds.

**Why multiple servers in a switcher menu?**
I keep two voice servers — one for daily use, one for demos. Hardcoding either was annoying. The menu lists both, the choice persists in `UserDefaults`, and switching forces a clean reconnect. If you only have one server, you can collapse the list to a single entry and skip the menu.

**Why ad-hoc code signing instead of a Developer ID certificate?**
This app runs on Macs I own. Ad-hoc signing (`codesign --force --sign -`) is enough for that. A real Developer ID would let you distribute the app to other people without Gatekeeper warnings, but it costs $99 a year and I'm the only user. If you want to share the app, you'll want a real signing identity.

**Why a Makefile that hand-rolls the `.app` bundle?**
There's no Xcode project. `swift build` produces a CLI binary; macOS apps need a `.app` bundle (binary plus `Info.plist` plus `Resources/`). Rather than maintain an Xcode project for a single-file app, the Makefile wraps the binary, writes the plist inline, copies the icon, and ad-hoc signs in about 20 lines. `make app` does everything.

## How it works

### App lifecycle

1. Launch reads the saved server selection from `UserDefaults`, sets up the menu bar, registers an `NWPathMonitor` for network changes, and runs an initial network check.
2. If the network check passes, the app opens a WebSocket connection. If not, it sets the status to "Waiting for home network" and waits for `NWPathMonitor` to fire.
3. Once connected, a 15-second ping timer starts. The app receives messages in a continuous loop.

### Network gating

The `checkNetwork()` function enumerates local IPv4 interfaces via `getifaddrs`, then matches each address against an allowed-subnets list. Each entry in the list is a CIDR block parsed at startup (`10.0.0.0/24`, `100.64.0.0/10` for Tailscale CGNAT, etc.). If any interface IP falls inside any allowed CIDR, reconnects are allowed. Otherwise the app suppresses reconnects entirely.

This list is hardcoded in `main.swift`. To add a new allowed network, add a CIDR entry and rebuild.

### Heartbeat

Every 15 seconds, the client sends a WebSocket ping. If the corresponding pong doesn't arrive within 10 seconds, the app considers the connection stale and force-reconnects. The server is expected to ping back on its own schedule (every 30 seconds in my server) so either end can detect a dead socket.

### Reconnection

Reconnect attempts use exponential backoff (3, 6, 12, 24, 48, 60 seconds). The delay resets to 3 seconds on every successful connection. Manual reconnect (Cmd-R) bypasses the backoff and the network check, which is useful when debugging.

### Audio playback

JSON text frames carry metadata (connection confirmation, notification info). Binary frames are MP3 audio data. The app appends each binary frame to an in-memory queue and plays them sequentially via `AVAudioPlayer`. Each instance plays from a `Data` blob in memory — no temp files, no disk I/O.

The mute toggle drops the audio but keeps the WebSocket connection. While muted, incoming audio briefly flashes the "playing" icon so you can still see that something arrived.

## Deployment

1. Install Xcode Command Line Tools (`xcode-select --install`)
2. Edit `Sources/main.swift` — set the `servers` list to your voice server URL(s) and the `allowedSubnets` list to your home LAN and any VPN ranges you use
3. `make app` to build the `.app` bundle (compiles, generates `Info.plist`, copies the icon, ad-hoc signs)
4. `make install` to copy it to `/Applications`
5. Open it from Spotlight or Launchpad — a small icon appears in the menu bar
6. To launch at login: System Settings → General → Login Items → Add the app

## Reference code

The `reference-code/` folder has working source files from my installation. These are real files, sanitized to remove my server hostnames and home subnet. They aren't production-hardened code; they're a reference for how one version of this looks. Use them to understand the patterns, then adapt for your own setup.

See [`reference-code/README.md`](./reference-code/README.md) for a file-by-file breakdown.

## Things to watch out for

- **Ad-hoc signing means this app is bound to the Mac that built it.** If you want to share the bundle, you need a real Developer ID certificate. Ad-hoc binaries also can't request entitlements like microphone access — fine for an audio-output-only app like this, but a constraint to remember.
- **The allowed-subnets list is hardcoded.** No config file, no environment override. To add a network, edit the source and rebuild. That's intentional — there are very few of these networks in practice — but if you switch home networks often, you'll want to plumb this through a `.env` or a preferences pane.
- **WebSocket binary frames have to be MP3 (or whatever AVAudioPlayer accepts).** If your server sends raw PCM or some other format, you'll need to add decoding before handing the data to AVAudioPlayer. The current code passes the bytes straight through.
- **There's no audio queue depth limit.** If the server pushes 200 audio messages while the user is muted, they'll all be discarded (mute drops audio without queuing). If they push 200 while playback is just slow, they'll all queue and eventually play. For a personal-use system this is fine; for anything noisier, add a max queue size.
- **`getifaddrs` returns IPv4 only in this code.** If your home network is IPv6-primary, you'll need to extend the network check to handle `AF_INET6` and parse v6 prefixes.
- **The mute state doesn't persist across launches.** If you quit while muted, the next launch starts unmuted. Easy fix with `UserDefaults` if it bothers you.

## What you could do differently

- **Add a notification center hook** so each incoming voice message also produces a native macOS notification with the title/body. Useful if you walk away from the Mac and want to see what was said.
- **Drive the `allowedSubnets` list from a config file** (or a preferences pane) so adding a network doesn't require a rebuild.
- **Cross-platform the client** to Linux or Windows. The Network framework and AVAudioPlayer are macOS-only, but the WebSocket-plus-audio-queue pattern translates trivially to a small TypeScript or Rust app on the other platforms.
- **Add volume control to the menu**. Currently it's just mute/unmute and the system volume. A slider would be straightforward via `AVAudioPlayer.volume`.
- **Per-server mute** — useful if you connect to multiple servers and want to mute work-related notifications without muting personal ones.
- **Rich notifications with images or URLs** by sending JSON frames alongside the audio and presenting them in `UNUserNotificationCenter`.
- **Use Server-Sent Events instead of WebSockets** if your server can't easily speak WebSocket. The audio-queue logic is unchanged; only the transport differs.
