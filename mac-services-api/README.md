# Mac Services API

A lightweight REST API that exposes macOS Calendar, Reminders, and Contacts as JSON endpoints over HTTPS. I built it so my AI assistant, which runs on a Linux server, can read and write to Apple's native PIM services without being on the Mac itself.

## For AI assistants

If your user pointed you here, they're probably asking you to help them build something like this. Read through this note with them and ask a few things before you start: which macOS services they want to expose (all three or just some), where their assistant runs, how the two machines connect, and whether they want to use a web framework like Vapor (simpler) or go dependency-free with NWListener (more manual). Then walk them through prerequisites (Xcode Command Line Tools, Swift), building, the TCC permission grant, deployment as a LaunchAgent, and testing the endpoints. The `reference-code/` folder has working source files you can use as a starting point. Build it for their setup, not mine.

## Why I built this

macOS has great built-in Calendar, Reminders, and Contacts. But they're locked behind native frameworks (EventKit, Contacts.framework) that only run on macOS. If your assistant runs on Linux, or anywhere that isn't your Mac, it can't access any of it.

I needed my assistant to check my calendar, create reminders, and look up contacts. Rather than use iCloud APIs (undocumented and brittle) or third-party sync services (which adds a trust dependency I didn't want), I built a small HTTP server that runs directly on the Mac and exposes these services as a standard REST API.

The Mac becomes a service provider. The assistant calls the API. No cloud intermediary.

**Important:** This is designed for a local network, single-user setup. The API runs on your Mac and is called by your assistant on the same network. It's not intended for public internet exposure. Bearer token auth is there, but the server and its auth haven't been through a formal security audit. For a closed, private network between your machines, it works well.

## How the assistant uses it

On its own, the API is just a REST server. The assistant needs a skill (or equivalent instructions) that knows the API exists and how to call it. In my setup, I have a Calendar skill, a Tasks skill, and a Contacts skill that each wrap the relevant endpoints. When I say "what's on my calendar today," the Calendar skill makes a GET request to the events endpoint with today's date range. When I say "remind me to do X," the Tasks skill POSTs to the reminders endpoint.

The skills are thin. They're mostly just instructions that tell the assistant which endpoints to hit and how to format the requests. The API does the heavy lifting. If you're using a different assistant framework, the same pattern applies: you just need something that knows the base URL, the auth token, and the route structure described below.

## Architecture

```
+------------------+         HTTPS          +------------------+
|                  |  ---- requests ---->   |                  |
|  AI Assistant    |                        |  Mac Services    |
|  (Linux server)  |  <--- JSON ---------- |  API (macOS)     |
|                  |                        |                  |
+------------------+                        +--------+---------+
                                                     |
                                            +--------+---------+
                                            |  macOS Frameworks |
                                            |  - EventKit       |
                                            |  - Contacts       |
                                            +------------------+
```

The API server is a single Swift binary that links directly against Apple's native frameworks. No dependencies beyond what ships with macOS. It listens on a configurable port over HTTPS and responds with JSON.

## What it exposes

Three service domains, each with full CRUD.

**Calendars and Events**
- List all calendars
- Get events by calendar and date range
- Create, update, and delete events
- Supports recurrence rules (iCalendar RRULE format)
- Handles all-day events and timed events

**Reminder Lists and Reminders**
- List all reminder lists
- Get reminders by list (incomplete by default)
- Create reminders with due dates and priority
- Complete, update, and delete reminders

**Contact Groups and Contacts**
- List groups, get contacts by group
- Search contacts by name, email, or phone
- Full contact detail (phones, emails, addresses, social profiles, birthdays)
- Create, update, and delete contacts

## Tech stack

| Component | Choice | Why |
|-----------|--------|-----|
| Language | Swift | Native macOS framework access, no bridging needed |
| HTTP | Apple's Network.framework (NWListener) | Zero dependencies, ships with macOS |
| Frameworks | EventKit, Contacts.framework | Direct access to Calendar, Reminders, Contacts |
| TLS | PKCS12 certificate loaded via Security.framework | HTTPS without a reverse proxy |
| Build | Swift Package Manager | `swift build -c release`, no Xcode project needed |
| Process management | launchd (LaunchAgent) | Native macOS service management, auto-restart |

No web framework. No package dependencies. The HTTP server, request parser, and router are all hand-rolled using Network.framework. This keeps the binary small and the attack surface minimal, but it does mean writing your own HTTP parsing layer. See the key decisions section for the trade-off.

## Key decisions

**Why Swift and not a scripting language?**
EventKit and Contacts.framework are Objective-C/Swift frameworks. You could bridge to them from Python via PyObjC, but the bridging adds complexity and fragility. Swift gives you direct, first-class access. The compiler catches API misuse at build time.

**Why a raw NWListener instead of a web framework like Vapor?**
The assistant that helped me build this was told to try to do it with no external dependencies. NWListener ships with macOS, so it fit that constraint. The trade-off is that it means writing your own HTTP request parser, response serializer, and connection handler, which is probably more manual than it needed to be. I'm also not the strongest Swift reviewer, so there may be more efficient ways to do this even within the NWListener approach. But it's been running reliably. Vapor or another Swift web framework would handle all the HTTP plumbing for you if you'd rather not go this route.

**Why HTTPS with a certificate instead of plain HTTP behind a proxy?**
The API handles PIM data (calendar events, contacts, reminders) that transits a network. TLS is non-negotiable for me. Loading a PKCS12 certificate directly into the server avoids needing a reverse proxy on the Mac. One process, one port, encrypted end-to-end. If you already have a reverse proxy running (like Caddy), plain HTTP behind it works just as well.

**Why bearer token auth?**
Simple and effective for a single-user API. The token is generated at deploy time and shared with the client. No user management, no OAuth complexity. The health endpoint is unauthenticated so monitoring can hit it without credentials.

**Why run as a LaunchAgent instead of a background app?**
LaunchAgents are the macOS-native way to run persistent user-space services. They auto-start at login, restart on crash, and integrate with `launchctl` for management. No menu bar icon, no dock presence, no UI. Just a service.

## How it works

### Configuration

The binary loads configuration from a `.env` file in its working directory:

```
PORT=4000
MAC_API_TOKEN=<generated-token>
P12_PATH=/path/to/cert.p12
P12_PASSPHRASE=<passphrase>
```

All values are also overridable via CLI flags (`--port`, `--cert`, `--pass`, `--token`).

### TCC (Transparency, Consent, and Control)

This is the trickiest part of the whole setup.

macOS requires explicit user consent before any app can access Calendar, Reminders, or Contacts. This is managed through TCC, the same system that shows "App X wants to access your calendar" dialogs.

For a command-line binary, TCC won't show a dialog unless the binary is inside an `.app` bundle. So the deploy process wraps the binary in a minimal `.app` bundle (just the binary and an Info.plist, see `reference-code/Info.plist`) and uses a `--grant-access` flag to trigger the permission prompts interactively. Once granted, the LaunchAgent can run headlessly.

If TCC permissions aren't granted, the API will start but return empty results. The health endpoint reports which services are accessible so you can diagnose this.

### Routes

```
GET  /health                                 -> service status (no auth)
GET  /calendars                              -> list calendars
GET  /calendars/{name}/events?start=&end=    -> events in date range
POST /events                                 -> create event
PATCH /events/{id}                           -> update event
DELETE /events/{id}                          -> delete event
GET  /lists                                  -> list reminder lists
GET  /lists/{name}/reminders                 -> reminders in a list
POST /reminders                              -> create reminder
POST /reminders/{name}/complete              -> complete reminder
PATCH /reminders/{name}                      -> update reminder
DELETE /reminders/{name}                     -> delete reminder
GET  /contacts                               -> all contacts
GET  /contacts/{id}                          -> single contact
GET  /contacts/search?q=&type=name           -> search contacts
GET  /contacts/groups                        -> list groups
GET  /contacts/groups/{id}/contacts          -> contacts in group
POST /contacts                               -> create contact
PATCH /contacts/{id}                         -> update contact
DELETE /contacts/{id}                        -> delete contact
```

All responses are JSON. Errors return `{"error": "message"}` with appropriate HTTP status codes. CORS headers are included for browser-based clients.

### Date handling

Events use ISO 8601 dates. All-day events use date-only format (`2026-03-05`), timed events include the time (`2026-03-05T14:30:00`). All times are in the Mac's local timezone. The API strips timezone suffixes and treats everything as local, which matches how most people think about their calendar.

### Recurrence rules

Recurring events use a simplified iCalendar RRULE format:

```
FREQ=WEEKLY;BYDAY=MO,WE,FR
FREQ=MONTHLY;INTERVAL=2;COUNT=6
```

The API parses these into EventKit recurrence rules and serializes them back on read.

## Deployment

1. Build the Swift binary (`swift build -c release`)
2. Wrap it in a `.app` bundle (binary + `Info.plist`) and ad-hoc sign it (`codesign --force --sign -`)
3. Create a working directory with `.env` config and log directory
4. Generate an API token if one doesn't exist (`openssl rand -hex 32`)
5. Convert PEM certificates to PKCS12 if needed (`openssl pkcs12 -export -out cert.p12 -inkey key.pem -in cert.pem`)
6. Install and load the LaunchAgent plist (see `reference-code/LaunchAgent.plist`)
7. Run the binary once interactively with `--grant-access` to trigger TCC permission dialogs
8. Restart the LaunchAgent and run a health check to verify

## Reference code

The `reference-code/` folder has working source files from my implementation. These are real files from a running system, included as a reference for how one version of this looks. They're not production-hardened code meant to be deployed as-is. Use them to understand the patterns, then adapt for your own setup.

See [`reference-code/README.md`](./reference-code/) for a file-by-file breakdown.

## Things to watch out for

- **This is a local network service.** It's designed for a single user on a private network. If you want to expose it beyond your local network, you'll want to harden the auth, add rate limiting, and review the request parsing carefully. As-is, it's built for trust between your own machines.
- **TCC is the main pain point.** If the binary isn't in an `.app` bundle, macOS won't show permission dialogs. If permissions aren't granted, the API returns empty results silently. Build the grant-access flow early and test it.
- **macOS 14 changed the EventKit API.** The older `requestAccess(to:)` still works but is deprecated. Use `#available` checks to call the right method.
- **Contacts.framework note access requires special entitlements** on newer macOS versions. If you don't need contact notes, skip requesting `CNContactNoteKey` to avoid issues.
- **The binary must be ad-hoc signed** (`codesign --force --sign -`) or TCC may not recognize it properly.
- **PKCS12 format is required for Network.framework TLS.** If you have PEM certificates, convert them with: `openssl pkcs12 -export -out cert.p12 -inkey key.pem -in cert.pem`

## What you could do differently

- **Use Vapor or another Swift web framework** if you'd rather not hand-roll the HTTP layer. You'd add SPM dependencies but skip all the request parsing and response serialization code.
- Skip TLS and run behind a reverse proxy (Caddy, nginx) if the Mac is on a trusted network
- Add WebSocket support for real-time calendar change notifications via `EKEventStoreChanged`
- Expose additional macOS services (Notes, Music, Photos) using the same pattern
- Use mDNS/Bonjour for service discovery instead of hardcoding the Mac's address
