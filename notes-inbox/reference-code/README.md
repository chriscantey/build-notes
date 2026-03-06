# Reference Code

Working source files from a running implementation of the Notes Inbox. These are real files, included so you can see how one version of this actually looks. They're not production-hardened and aren't meant to be deployed as-is. Read through them to understand the patterns, then build your own.

## Files

| File | What it is |
|------|------------|
| `server.ts` | The complete inbox API server. Single file, no dependencies. Handles all routes, auth, file I/O, and logging. |
| `Dockerfile` | Alpine-based Bun container. Copies the server and runs it. |
| `docker-compose.yml` | Container config with volume mounts for data, certs, and config. |
| `package.json` | Minimal project file. No dependencies listed. |

## Notes

- The server reads its auth token from a `.env` file at a configurable path. In this implementation, it reads from the PAI (Personal AI) config directory, but you'd point it wherever you keep your environment config.
- Paths in `docker-compose.yml` reference a specific directory layout. Adjust the volume mounts for your setup.
- The server accepts PEM certificates directly (Bun handles PEM natively, unlike the Mac Services API which needs PKCS12 for Network.framework).
- There's a legacy migration path from an older `voice-notes.json` format. You won't need this unless you're migrating from a previous version. It's left in as an example of how to handle format changes gracefully.
