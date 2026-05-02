# Reference Code

Working source files from a running AssistantVoice install. Sanitized to remove server hostnames and home subnets — both are placeholders you'll edit before building.

| File | What it does |
|------|-------------|
| `Package.swift` | Swift Package Manager manifest. One executable target, macOS 12+, no external dependencies. |
| `Makefile` | Build orchestration. `make app` compiles, generates `Info.plist` inline, copies the icon, and ad-hoc signs the `.app` bundle. `make install` copies it to `/Applications`. |
| `Info.plist` | Standalone reference for the bundle plist. The Makefile generates this inline at build time, but having it as a file makes the `LSUIElement` (menu-bar-only) flag and other keys easier to read. |
| `main.swift` | The entire app. Single Swift file (~600 lines) covering menu bar UI, WebSocket client with ping/pong heartbeat, network-aware reconnection, audio queue, and mute toggle. |

## What you'll edit before building

In `main.swift`, two things must be changed for your setup:

**1. The `servers` list.** Replace the `voice.example.com` and `demo.example.com` placeholders with your actual voice server URL(s). If you only have one server, drop the second entry — the menu will still work with a single item.

```swift
let servers: [VoiceServer] = [
    VoiceServer(name: "Main", host: "your-voice-server.example.com",
                url: "wss://your-voice-server.example.com:8889/stream"),
]
```

**2. The `allowedSubnets` list.** Replace `192.168.1.0/24` with your home LAN's CIDR. Add or remove VPN ranges as needed. The Tailscale CGNAT range (`100.64.0.0/10`) is left in as a common case — if you don't use Tailscale, drop it.

```swift
let allowedSubnets: [(network: UInt32, mask: UInt32)] = [
    cidr("10.0.0.0/24"),       // Your home LAN
    cidr("100.64.0.0/10"),     // Tailscale (optional)
]
```

In `Makefile`, change `BUNDLE_ID` to something unique to you. The placeholder `com.example.voice-client` is fine for local use but not for distribution.

## What you might also want

- `AppIcon.icns` — drop your own icon next to `Makefile` and the build will pick it up automatically. Without one, the bundle uses the system default.
- A LaunchAgent plist if you want this to run at login as a true background service. The simpler approach is to add the `.app` to System Settings → General → Login Items — that gives you the same effect without writing a plist.

## What you don't need

- An Xcode project. `swift build` plus the Makefile is the whole build system.
- A Developer ID certificate. Ad-hoc signing (`codesign --force --sign -`) is sufficient for personal use on your own Mac. You only need a real certificate if you distribute the app to other machines.
- A separate config file for the server URL. With only one or two servers, hardcoding in `main.swift` and rebuilding when you need to change is simpler than parsing a config. If you add a third server or start switching often, plumb a `.env` or a `~/Library/Preferences/...` plist through.
