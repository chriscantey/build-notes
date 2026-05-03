#!/usr/bin/env bun
// Voice Server — accepts text via /notify, generates speech via the configured
// provider, and broadcasts the resulting MP3 to all connected WebSocket clients.
//
// Two listeners:
//   - HTTP on PORT          (local browsers and headless sinks)
//   - HTTPS on WSS_PORT     (remote clients reachable over a network or VPN)
// The HTTPS listener only opens if TLS certs are present on disk.

import { join } from "path";
import { existsSync } from "fs";

// Load .env from the configured app directory. The Dockerfile mounts your
// .env file at /app/.env (see docker-compose.yml).
const envPath = process.env.ENV_PATH || '/app/.env';
if (existsSync(envPath)) {
  const envContent = await Bun.file(envPath).text();
  envContent.split('\n').forEach(line => {
    const [key, value] = line.split('=');
    if (key && value && !key.startsWith('#')) {
      process.env[key.trim()] = value.trim();
    }
  });
}

const PORT = parseInt(process.env.PAI_VOICE_STREAM_PORT || "8888");
const WSS_PORT = parseInt(process.env.PAI_VOICE_WSS_PORT || "8889");

// TLS for the HTTPS listener. If certs are missing the HTTPS listener simply
// doesn't start — fine for local-only setups, no error.
const certsDir = process.env.CERTS_DIR || '/app/certs';
const certFile = join(certsDir, 'fullchain.pem');
const keyFile = join(certsDir, 'privkey.pem');
const tlsAvailable = existsSync(certFile) && existsSync(keyFile);

// Provider config. TTS_PRIMARY picks the first-choice provider; Kokoro is
// always the last-resort fallback because it's local and effectively never fails.
const TTS_PRIMARY = process.env.TTS_PRIMARY || "kokoro";

const KOKORO_URL = process.env.KOKORO_URL || "http://voice-server-kokoro:7880";
const KOKORO_VOICE = process.env.KOKORO_VOICE || "bf_emma";

const CHATTERBOX_URL = process.env.CHATTERBOX_URL || "http://chatterbox-tts:8890";
const CHATTERBOX_VOICE = process.env.CHATTERBOX_VOICE || "rachel";
const CHATTERBOX_TIMEOUT = parseInt(process.env.CHATTERBOX_TIMEOUT || "10000");

// Connected clients and their last pong timestamp
const wsClients = new Set<any>();
const clientLastPong = new Map<any, number>();

// Heartbeat
const WS_PING_INTERVAL = 30_000;
const WS_STALE_TIMEOUT = 90_000;


// --- Provider implementations ----------------------------------------------

async function generateSpeechChatterbox(text: string): Promise<ArrayBuffer> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), CHATTERBOX_TIMEOUT);

  try {
    const response = await fetch(`${CHATTERBOX_URL}/v1/audio/speech`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        input: text,
        voice: CHATTERBOX_VOICE,
        response_format: 'mp3',
      }),
      signal: controller.signal,
    });

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`Chatterbox TTS error: ${response.status} - ${errorText}`);
    }

    return await response.arrayBuffer();
  } finally {
    clearTimeout(timeout);
  }
}

async function generateSpeechKokoro(text: string, voiceName?: string): Promise<ArrayBuffer> {
  const voice = voiceName || KOKORO_VOICE;
  const response = await fetch(`${KOKORO_URL}/tts`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text, voice }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(`Kokoro TTS error: ${response.status} - ${errorText}`);
  }

  return await response.arrayBuffer();
}

// Tiered provider router: try primary, fall back to Kokoro on failure.
async function generateSpeech(text: string, voiceName?: string): Promise<ArrayBuffer> {
  if (TTS_PRIMARY === 'chatterbox') {
    try {
      const audio = await generateSpeechChatterbox(text);
      console.log(`TTS: Chatterbox (voice: ${CHATTERBOX_VOICE}) succeeded`);
      return audio;
    } catch (err: any) {
      const reason = err.name === 'AbortError' ? 'timeout' : err.message;
      console.log(`TTS: Chatterbox failed (${reason}), falling back to Kokoro`);
    }
  }

  // Kokoro fallback (or primary if TTS_PRIMARY=kokoro)
  const audio = await generateSpeechKokoro(text, voiceName);
  console.log(`TTS: Kokoro (voice: ${voiceName || KOKORO_VOICE}) succeeded`);
  return audio;
}


// --- Input sanitization ----------------------------------------------------

// Strip control characters, markdown, and shell metacharacters before sending
// to TTS. Truncate to 500 characters so a runaway prompt can't wedge the engine.
function sanitizeForSpeech(input: string): string {
  return input
    .replace(/\[[^\]]*\]/g, '')        // bracketed prosody/style hints
    .replace(/<script/gi, '')
    .replace(/\.\.\//g, '')
    .replace(/[;&|><`$\\]/g, '')
    .replace(/\*\*([^*]+)\*\*/g, '$1') // bold
    .replace(/\*([^*]+)\*/g, '$1')     // italic
    .replace(/`([^`]+)`/g, '$1')       // inline code
    .replace(/#{1,6}\s+/g, '')         // markdown headers
    .trim()
    .substring(0, 500);
}


// --- HTTP server (local) ---------------------------------------------------

const server = Bun.serve({
  port: PORT,
  hostname: '0.0.0.0',

  async fetch(req: Request) {
    const url = new URL(req.url);

    const headers = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    };

    if (req.method === 'OPTIONS') {
      return new Response(null, { headers });
    }

    // WebSocket upgrade for audio streaming
    if (url.pathname === '/stream') {
      const success = server.upgrade(req);
      if (success) return undefined;
    }

    // POST /notify — generate speech and broadcast to WebSocket clients
    if (url.pathname === '/notify' && req.method === 'POST') {
      try {
        const data = await req.json();
        const title = data.title || "PAI Notification";
        const message = data.message || "Task completed";
        const voiceEnabled = data.voice_enabled !== false;
        const voiceOverride = data.voice_name || null;

        if (!message) {
          return new Response(
            JSON.stringify({ status: 'error', message: 'No message provided' }),
            { headers: { ...headers, 'Content-Type': 'application/json' }, status: 400 }
          );
        }

        console.log(`Notification: "${title}" - "${message.substring(0, 50)}..."`);

        const cleanedMessage = sanitizeForSpeech(message);
        if (!cleanedMessage) {
          return new Response(
            JSON.stringify({ status: 'error', message: 'Message invalid after sanitization' }),
            { headers: { ...headers, 'Content-Type': 'application/json' }, status: 400 }
          );
        }

        // Voice override is accepted only if it matches the Kokoro voice format.
        let voice = KOKORO_VOICE;
        if (voiceOverride && /^[a-z]{2}_[a-z]+$/.test(voiceOverride)) {
          voice = voiceOverride;
        }

        if (voiceEnabled) {
          const audioBuffer = await generateSpeech(cleanedMessage, voice);

          // Send JSON metadata then audio bytes as separate WebSocket messages.
          // Bun's send() is synchronous so both sends complete atomically
          // within the same microtask — clients see metadata immediately
          // before the audio frame.
          const wsMessage = JSON.stringify({
            type: 'notification',
            title,
            message: cleanedMessage,
            size: audioBuffer.byteLength,
          });

          wsClients.forEach(client => {
            try {
              const metaResult = client.send(wsMessage);
              const audioResult = client.send(audioBuffer);
              // Bun.send() returns: bytes on success, 0 on backpressure drop,
              // or a negative number if the socket is dead. Close dead sockets
              // so the client can reconnect cleanly.
              if (metaResult === 0 || audioResult === 0) {
                console.error(`[BACKPRESSURE] Send dropped! meta=${metaResult} audio=${audioResult}`);
              } else if (metaResult < 0 || audioResult < 0) {
                console.error(`[DEAD SOCKET] Send failed; closing.`);
                try { client.close(); } catch {}
                wsClients.delete(client);
                clientLastPong.delete(client);
              }
            } catch (err) {
              console.error('Failed to send to client:', err);
              try { client.close(); } catch {}
              wsClients.delete(client);
              clientLastPong.delete(client);
            }
          });

          console.log(`Streamed ${audioBuffer.byteLength} bytes to ${wsClients.size} client(s)`);
        }

        return new Response(
          JSON.stringify({ status: 'success', message: 'Notification sent' }),
          { headers: { ...headers, 'Content-Type': 'application/json' }, status: 200 }
        );
      } catch (error: any) {
        console.error('Notification error:', error);
        return new Response(
          JSON.stringify({ status: 'error', message: error.message || 'Internal server error' }),
          { headers: { ...headers, 'Content-Type': 'application/json' }, status: 500 }
        );
      }
    }

    if (url.pathname === '/health') {
      return new Response(
        JSON.stringify({
          status: 'ok',
          port: PORT,
          clients: wsClients.size,
          tts_primary: TTS_PRIMARY,
          fallback_chain: TTS_PRIMARY === 'chatterbox' ? ['chatterbox', 'kokoro'] : ['kokoro'],
          chatterbox: { url: CHATTERBOX_URL, voice: CHATTERBOX_VOICE, timeout_ms: CHATTERBOX_TIMEOUT },
          kokoro: { url: KOKORO_URL, voice: KOKORO_VOICE },
        }),
        { headers: { ...headers, 'Content-Type': 'application/json' } }
      );
    }

    return new Response('Voice Server — POST /notify, GET /health, WS /stream', {
      headers: { ...headers, 'Content-Type': 'text/plain' },
    });
  },

  websocket: {
    open(ws) {
      console.log('WebSocket client connected');
      wsClients.add(ws);
      clientLastPong.set(ws, Date.now());
      ws.send(JSON.stringify({ type: 'connected', clients: wsClients.size }));
    },
    message(ws, message) {
      console.log('Received message from client:', message);
    },
    close(ws) {
      console.log('WebSocket client disconnected');
      wsClients.delete(ws);
      clientLastPong.delete(ws);
    },
    error(ws, error) {
      console.error('WebSocket error:', error);
      wsClients.delete(ws);
      clientLastPong.delete(ws);
    },
    pong(ws) {
      clientLastPong.set(ws, Date.now());
    },
  },
});


// --- HTTPS server (remote) -------------------------------------------------

let wssServer: any = null;
if (tlsAvailable) {
  wssServer = Bun.serve({
    port: WSS_PORT,
    hostname: '0.0.0.0',
    tls: {
      key: Bun.file(keyFile),
      cert: Bun.file(certFile),
    },

    async fetch(req: Request) {
      const url = new URL(req.url);

      const headers = {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type',
      };

      if (req.method === 'OPTIONS') {
        return new Response(null, { headers });
      }

      if (url.pathname === '/stream') {
        const success = wssServer.upgrade(req);
        if (success) return undefined;
      }

      if (url.pathname === '/health') {
        return new Response(
          JSON.stringify({ status: 'ok', port: WSS_PORT, tls: true, clients: wsClients.size }),
          { headers: { ...headers, 'Content-Type': 'application/json' } }
        );
      }

      return new Response('Voice Server (WSS) — /stream or /health', {
        headers: { ...headers, 'Content-Type': 'text/plain' },
      });
    },

    websocket: {
      open(ws) {
        console.log('WSS client connected (remote)');
        wsClients.add(ws);
        clientLastPong.set(ws, Date.now());
        ws.send(JSON.stringify({ type: 'connected', clients: wsClients.size }));
      },
      message(ws, message) {
        console.log('WSS received message:', message);
      },
      close(ws) {
        console.log('WSS client disconnected');
        wsClients.delete(ws);
        clientLastPong.delete(ws);
      },
      error(ws, error) {
        console.error('WSS error:', error);
        wsClients.delete(ws);
        clientLastPong.delete(ws);
      },
      pong(ws) {
        clientLastPong.set(ws, Date.now());
      },
    },
  });
}


// --- Boot logging ----------------------------------------------------------

console.log(`Voice Server running on http://0.0.0.0:${PORT}`);
console.log(`TTS Primary: ${TTS_PRIMARY}`);
if (TTS_PRIMARY === 'chatterbox') {
  console.log(`  Chatterbox: ${CHATTERBOX_URL} (voice: ${CHATTERBOX_VOICE}, timeout: ${CHATTERBOX_TIMEOUT}ms)`);
  console.log(`  Fallback: Kokoro (${KOKORO_URL}, voice: ${KOKORO_VOICE})`);
} else {
  console.log(`  Kokoro: ${KOKORO_URL} (voice: ${KOKORO_VOICE})`);
}

if (wssServer) {
  console.log(`WSS listener on https://0.0.0.0:${WSS_PORT} (remote streaming)`);
} else {
  console.log(`WSS listener disabled (no certs at ${certsDir})`);
}


// --- Heartbeat -------------------------------------------------------------
// Periodically ping all clients; drop those that haven't pong'd recently.
setInterval(() => {
  const now = Date.now();
  for (const client of wsClients) {
    const lastPong = clientLastPong.get(client) ?? 0;
    if (now - lastPong > WS_STALE_TIMEOUT) {
      console.log('Removing stale WebSocket client (no pong in 90s)');
      try { client.close(); } catch {}
      wsClients.delete(client);
      clientLastPong.delete(client);
    } else {
      try {
        client.ping();
      } catch {
        console.log('Ping failed, removing client');
        wsClients.delete(client);
        clientLastPong.delete(client);
      }
    }
  }
}, WS_PING_INTERVAL);
