# Reference Code

These are real source files from a working version of this project. They're here as a reference for how one implementation looks, not as production-ready code to deploy as-is.

If you're building your own version, read through these to understand the patterns and then adapt them to your setup. Your assistant can use these as a starting point and build something tailored to your needs, framework choices, and security requirements.

## Files

| File | What it covers |
|------|---------------|
| `Package.swift` | SPM project definition with framework linking |
| `Server.swift` | HTTP types, request parser, TLS setup, NWListener server |
| `CalendarAPI.swift` | EventKit handlers for calendars and events |
| `RemindersAPI.swift` | EventKit handlers for reminder lists and reminders |
| `ContactsAPI.swift` | Contacts.framework handlers for contacts and groups |
| `Info.plist` | Minimal .app bundle plist for TCC recognition |
| `LaunchAgent.plist` | launchd plist for running as a persistent service |
