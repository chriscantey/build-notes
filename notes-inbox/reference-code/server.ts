#!/usr/bin/env bun
// Inbox API Server
// General-purpose inbox for voice notes, ideas, links, and items to process
// Single file, no dependencies beyond Bun

import { existsSync, readFileSync, writeFileSync, mkdirSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { randomUUID } from "crypto";

const PORT = parseInt(process.env.INBOX_API_PORT || "4000");
const CONFIG_DIR = process.env.CONFIG_DIR || join(homedir(), ".config/inbox");
const DATA_DIR = process.env.DATA_DIR || join(homedir(), "data");
const CERTS_DIR = process.env.CERTS_DIR || join(homedir(), "certs");
const INBOX_FILE = join(DATA_DIR, "inbox.json");
const LOG_FILE = join(DATA_DIR, "inbox.log");

// Load auth token from .env
const envPath = join(CONFIG_DIR, ".env");
let API_TOKEN: string | null = null;

if (existsSync(envPath)) {
  const envContent = readFileSync(envPath, "utf-8");
  envContent.split("\n").forEach((line) => {
    const [key, value] = line.split("=");
    if (key?.trim() === "INBOX_API_TOKEN") {
      API_TOKEN = value?.trim() || null;
    }
  });
}

// Ensure data directory exists
if (!existsSync(DATA_DIR)) {
  mkdirSync(DATA_DIR, { recursive: true });
}

// Initialize inbox file if it doesn't exist
if (!existsSync(INBOX_FILE)) {
  writeFileSync(INBOX_FILE, JSON.stringify({ items: [], last_received: null }, null, 2));
}

// Types
interface ItemMetadata {
  recorded_at?: string;
  location?: {
    lat: number;
    lon: number;
  };
  [key: string]: unknown;
}

interface InboxItem {
  id: string;
  content: string;
  received_at: string;
  status: "inbox" | "processed" | "archived";
  type?: string;  // e.g., "voice", "text", "link", "task"
  source: string; // e.g., "shortcut", "webhook", "api"
  tags: string[];
  discussion_notes: string;
  processed_at: string | null;
  metadata: ItemMetadata;
}

interface InboxData {
  items: InboxItem[];
  last_received: string | null;
}

// Log events to a rotating log file (keeps last 1000 entries)
function logEvent(event: string, details?: object) {
  const timestamp = new Date().toISOString();
  const logLine = JSON.stringify({ timestamp, event, ...details }) + "\n";
  try {
    const existing = existsSync(LOG_FILE) ? readFileSync(LOG_FILE, "utf-8") : "";
    const lines = existing.split("\n").filter(Boolean).slice(-999);
    lines.push(logLine.trim());
    writeFileSync(LOG_FILE, lines.join("\n") + "\n");
  } catch (e) {
    console.error("Failed to write log:", e);
  }
}

// Get client IP from request (supports Cloudflare and proxy headers)
function getClientIP(req: Request): string {
  const cfIP = req.headers.get("CF-Connecting-IP");
  if (cfIP) return cfIP;
  const xForwardedFor = req.headers.get("X-Forwarded-For");
  if (xForwardedFor) return xForwardedFor.split(",")[0].trim();
  const xRealIP = req.headers.get("X-Real-IP");
  if (xRealIP) return xRealIP;
  return "unknown";
}

// Validate auth token from header
function validateAuth(req: Request): boolean {
  if (!API_TOKEN) {
    console.warn("Warning: INBOX_API_TOKEN not set - auth disabled");
    return true;
  }
  const authHeader = req.headers.get("X-Sync-Token") || req.headers.get("Authorization")?.replace("Bearer ", "");
  return authHeader === API_TOKEN;
}

// Read inbox data from JSON file
function readInbox(): InboxData {
  try {
    return JSON.parse(readFileSync(INBOX_FILE, "utf-8"));
  } catch {
    return { items: [], last_received: null };
  }
}

// Write inbox data to JSON file
function writeInbox(data: InboxData) {
  writeFileSync(INBOX_FILE, JSON.stringify(data, null, 2));
}

// Validate UUID format
function isValidUUID(str: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(str);
}

const server = Bun.serve({
  port: PORT,
  hostname: "0.0.0.0",
  tls: {
    key: Bun.file(join(CERTS_DIR, "privkey.pem")),
    cert: Bun.file(join(CERTS_DIR, "fullchain.pem")),
  },

  async fetch(req: Request) {
    const url = new URL(req.url);

    const headers = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, PATCH, DELETE, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, X-Sync-Token, Authorization",
      "Content-Type": "application/json",
    };

    if (req.method === "OPTIONS") {
      return new Response(null, { headers });
    }

    // Health check (no auth required)
    if (url.pathname === "/health") {
      const data = readInbox();
      const inboxCount = data.items.filter((n) => n.status === "inbox").length;

      return new Response(
        JSON.stringify({
          status: "ok",
          service: "inbox-api",
          port: PORT,
          auth_enabled: !!API_TOKEN,
          last_received: data.last_received,
          total_items: data.items.length,
          inbox_count: inboxCount,
        }),
        { headers }
      );
    }

    // POST /item - Add new inbox item (no API token required)
    if (url.pathname === "/item" && req.method === "POST") {
      try {
        const body = await req.json();
        const content = body.text || body.content || body.transcript || "";

        if (!content) {
          return new Response(
            JSON.stringify({ error: "Invalid payload", message: "Missing content (text, content, or transcript field)" }),
            { headers, status: 400 }
          );
        }

        // Build metadata from extra fields
        const metadata: ItemMetadata = {};
        if (body.recorded_at) {
          metadata.recorded_at = body.recorded_at;
        }
        if (body.location && body.location.lat != null && body.location.lon != null) {
          const lat = parseFloat(body.location.lat);
          const lon = parseFloat(body.location.lon);
          if (!isNaN(lat) && !isNaN(lon)) {
            metadata.location = { lat, lon };
          }
        }
        if (body.metadata && typeof body.metadata === "object") {
          Object.assign(metadata, body.metadata);
        }

        const item: InboxItem = {
          id: randomUUID(),
          content: content.substring(0, 50000).trim(),
          received_at: new Date().toISOString(),
          status: "inbox",
          type: body.type || "text",
          source: body.source || "api",
          tags: Array.isArray(body.tags) ? body.tags.map((t: any) => String(t).substring(0, 50)) : [],
          discussion_notes: "",
          processed_at: null,
          metadata,
        };

        const data = readInbox();
        data.items.unshift(item);
        data.last_received = item.received_at;
        writeInbox(data);

        const preview = item.content.substring(0, 50).replace(/\n/g, " ");
        logEvent("item_received", { id: item.id, source: item.source, type: item.type, has_location: !!metadata.location, ip: getClientIP(req) });
        console.log(`[${item.source}] Received: "${preview}..."`);

        return new Response(
          JSON.stringify({
            status: "success",
            message: "Item saved to inbox",
            id: item.id,
            received_at: item.received_at,
          }),
          { headers }
        );
      } catch (error: any) {
        logEvent("item_error", { error: error.message, ip: getClientIP(req) });
        return new Response(
          JSON.stringify({ error: "Server error", message: error.message }),
          { headers, status: 500 }
        );
      }
    }

    // All other endpoints require auth
    if (!validateAuth(req)) {
      logEvent("auth_failed", { path: url.pathname, ip: getClientIP(req) });
      return new Response(
        JSON.stringify({ error: "Unauthorized", message: "Invalid or missing auth token" }),
        { headers, status: 401 }
      );
    }

    // GET /items - List items with optional filtering
    if (url.pathname === "/items" && req.method === "GET") {
      try {
        const data = readInbox();
        let items = data.items;

        const status = url.searchParams.get("status");
        if (status) items = items.filter((n) => n.status === status);

        const type = url.searchParams.get("type");
        if (type) items = items.filter((n) => n.type === type);

        const source = url.searchParams.get("source");
        if (source) items = items.filter((n) => n.source === source);

        const tag = url.searchParams.get("tag");
        if (tag) items = items.filter((n) => n.tags.includes(tag));

        const search = url.searchParams.get("search");
        if (search) {
          const query = search.toLowerCase();
          items = items.filter((n) => n.content.toLowerCase().includes(query));
        }

        const limit = parseInt(url.searchParams.get("limit") || "100");
        items = items.slice(0, limit);

        return new Response(
          JSON.stringify({ items, total: data.items.length, filtered: items.length }),
          { headers }
        );
      } catch (error: any) {
        return new Response(
          JSON.stringify({ error: "Server error", message: error.message }),
          { headers, status: 500 }
        );
      }
    }

    // GET /items/:id - Get single item
    const getMatch = url.pathname.match(/^\/items\/([a-f0-9-]+)$/i);
    if (getMatch && req.method === "GET") {
      const id = getMatch[1];
      if (!isValidUUID(id)) {
        return new Response(JSON.stringify({ error: "Invalid ID" }), { headers, status: 400 });
      }
      const data = readInbox();
      const item = data.items.find((n) => n.id === id);
      if (!item) {
        return new Response(JSON.stringify({ error: "Not found" }), { headers, status: 404 });
      }
      return new Response(JSON.stringify(item), { headers });
    }

    // PATCH /items/:id - Update item
    const patchMatch = url.pathname.match(/^\/items\/([a-f0-9-]+)$/i);
    if (patchMatch && req.method === "PATCH") {
      try {
        const id = patchMatch[1];
        if (!isValidUUID(id)) {
          return new Response(JSON.stringify({ error: "Invalid ID" }), { headers, status: 400 });
        }

        const body = await req.json();
        const data = readInbox();
        const itemIndex = data.items.findIndex((n) => n.id === id);

        if (itemIndex === -1) {
          return new Response(JSON.stringify({ error: "Not found" }), { headers, status: 404 });
        }

        const item = data.items[itemIndex];

        if (body.status && ["inbox", "processed", "archived"].includes(body.status)) {
          item.status = body.status;
          if (body.status === "processed" || body.status === "archived") {
            item.processed_at = new Date().toISOString();
          }
        }
        if (Array.isArray(body.tags)) {
          item.tags = body.tags.map((t: any) => String(t).substring(0, 50));
        }
        if (typeof body.discussion_notes === "string") {
          item.discussion_notes = body.discussion_notes.substring(0, 10000);
        }
        if (typeof body.type === "string") {
          item.type = body.type.substring(0, 50);
        }

        data.items[itemIndex] = item;
        writeInbox(data);

        logEvent("item_updated", { id, status: item.status, ip: getClientIP(req) });
        return new Response(JSON.stringify(item), { headers });
      } catch (error: any) {
        return new Response(
          JSON.stringify({ error: "Server error", message: error.message }),
          { headers, status: 500 }
        );
      }
    }

    // DELETE /items/:id - Delete item
    const deleteMatch = url.pathname.match(/^\/items\/([a-f0-9-]+)$/i);
    if (deleteMatch && req.method === "DELETE") {
      try {
        const id = deleteMatch[1];
        if (!isValidUUID(id)) {
          return new Response(JSON.stringify({ error: "Invalid ID" }), { headers, status: 400 });
        }

        const data = readInbox();
        const itemIndex = data.items.findIndex((n) => n.id === id);
        if (itemIndex === -1) {
          return new Response(JSON.stringify({ error: "Not found" }), { headers, status: 404 });
        }

        const [deleted] = data.items.splice(itemIndex, 1);
        writeInbox(data);

        logEvent("item_deleted", { id, ip: getClientIP(req) });
        return new Response(JSON.stringify({ status: "deleted", id: deleted.id }), { headers });
      } catch (error: any) {
        return new Response(
          JSON.stringify({ error: "Server error", message: error.message }),
          { headers, status: 500 }
        );
      }
    }

    // Default - list available endpoints
    return new Response(
      JSON.stringify({
        service: "Inbox API",
        endpoints: [
          "POST /item - Add new inbox item (no auth)",
          "GET /items - List items (?status=inbox&type=voice&source=shortcut&tag=web&search=term&limit=100)",
          "GET /items/:id - Get single item",
          "PATCH /items/:id - Update item (status, tags, discussion_notes, type)",
          "DELETE /items/:id - Delete item",
          "GET /health - Health check (no auth)",
        ],
      }),
      { headers }
    );
  },
});

console.log(`Inbox API running on https://0.0.0.0:${PORT}`);
console.log(`   Auth: ${API_TOKEN ? "enabled" : "DISABLED (set INBOX_API_TOKEN in .env)"}`);
console.log(`   Data: ${INBOX_FILE}`);
