import { randomBytes, randomUUID } from "node:crypto";
import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { Database } from "bun:sqlite";
import type { ServerWebSocket } from "bun";

type Role = "viewer" | "agent";

type ClientData = {
  role?: Role;
  apiKey?: string;
  hostId?: string;
  hostName?: string;
};

type StoredUser = {
  apiKey: string;
  createdAt: string;
  client?: string;
  version?: string;
};

type RelayResult = {
  requestId: string;
  delivered: number;
  payload?: Record<string, unknown>;
  timedOut?: boolean;
};

type PendingRequest = {
  apiKey: string;
  delivered: number;
  timer: ReturnType<typeof setTimeout>;
  payload: Record<string, unknown>;
  complete: (
    result: RelayResult,
    notifyViewers?: boolean,
    exclude?: ServerWebSocket<ClientData>,
  ) => void;
  agent?: ServerWebSocket<ClientData>;
};

const port = Number(process.env.PORT ?? process.env.CODEISLAND_RELAY_PORT ?? "8787");
const dataFile = resolve(process.env.CODEISLAND_RELAY_DB ?? "relay-data/codeisland-relay.sqlite");
const requestTimeoutMs = Number(process.env.CODEISLAND_RELAY_REQUEST_TIMEOUT_MS ?? "300000");
const resourceDir = resolve(import.meta.dir, "resources");

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type,Authorization",
};

mkdirSync(dirname(dataFile), { recursive: true });
const db = new Database(dataFile);
db.run(`
  CREATE TABLE IF NOT EXISTS users (
    api_key TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    client TEXT,
    version TEXT
  )
`);

const usersByKey = new Map(loadUsers().map((user) => [user.apiKey, user]));
const viewersByKey = new Map<string, Set<ServerWebSocket<ClientData>>>();
const pendingRequests = new Map<string, PendingRequest>();

function loadUsers(): StoredUser[] {
  return db.query(`
    SELECT
      api_key AS apiKey,
      created_at AS createdAt,
      client,
      version
    FROM users
  `).all() as StoredUser[];
}

function saveUser(user: StoredUser) {
  db.query(`
    INSERT INTO users (api_key, created_at, client, version)
    VALUES (?, ?, ?, ?)
  `).run(user.apiKey, user.createdAt, user.client ?? null, user.version ?? null);
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders,
    },
  });
}

function resourceResponse(name: string, contentType: string) {
  const file = Bun.file(resolve(resourceDir, name));
  return new Response(file, {
    headers: {
      "Content-Type": contentType,
      "Cache-Control": "no-cache",
      ...corsHeaders,
    },
  });
}

function apiKey() {
  let key = "";
  do {
    key = `ci_${randomBytes(32).toString("base64url")}`;
  } while (usersByKey.has(key));
  return key;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function nonEmptyString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function bearerAPIKey(request: Request) {
  const authorization = request.headers.get("Authorization") ?? "";
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  return nonEmptyString(match?.[1]);
}

function safeSend(ws: ServerWebSocket<ClientData>, body: unknown) {
  try {
    ws.send(JSON.stringify(body));
  } catch {
    // The other side may already have closed. Pending timeout cleanup handles the rest.
  }
}

function normalizeEventName(name: string) {
  switch (name) {
    case "permission_request":
      return "PermissionRequest";
    case "notification":
      return "Notification";
    default:
      return name;
  }
}

function firstEventName(payload: Record<string, unknown>) {
  return nonEmptyString(payload.hook_event_name)
    ?? nonEmptyString(payload.hookEventName)
    ?? nonEmptyString(payload.event_name)
    ?? nonEmptyString(payload.eventName)
    ?? nonEmptyString(payload.event)
    ?? "";
}

function defaultResponse(payload: Record<string, unknown>) {
  const eventName = normalizeEventName(firstEventName(payload));
  if (eventName === "PermissionRequest") {
    return {
      hookSpecificOutput: {
        hookEventName: "PermissionRequest",
        decision: { behavior: "deny" },
      },
    };
  }
  if (eventName === "Notification") {
    return { hookSpecificOutput: { hookEventName: "Notification" } };
  }
  return {};
}

function relayHostId(hostId: string) {
  return hostId.startsWith("relay:") ? hostId : `relay:${hostId}`;
}

function viewerSet(apiKey: string) {
  let set = viewersByKey.get(apiKey);
  if (!set) {
    set = new Set();
    viewersByKey.set(apiKey, set);
  }
  return set;
}

function removeViewer(ws: ServerWebSocket<ClientData>) {
  const key = ws.data.apiKey;
  if (!key) return;
  const set = viewersByKey.get(key);
  if (!set) return;
  set.delete(ws);
  if (set.size === 0) viewersByKey.delete(key);
}

function cleanupAgentPending(ws: ServerWebSocket<ClientData>) {
  for (const [requestId, pending] of pendingRequests) {
    if (pending.agent !== ws) continue;
    const payload = defaultResponse(pending.payload);
    pending.complete({ requestId, delivered: pending.delivered, payload, timedOut: true }, true);
  }
}

function broadcastResolved(
  apiKey: string,
  requestId: string,
  payload: Record<string, unknown>,
  exclude?: ServerWebSocket<ClientData>,
) {
  const viewers = viewersByKey.get(apiKey);
  if (!viewers) return;
  for (const viewer of viewers) {
    if (viewer === exclude) continue;
    safeSend(viewer, { type: "request_resolved", requestId, payload });
  }
}

function handleHello(ws: ServerWebSocket<ClientData>, msg: Record<string, unknown>) {
  const role = msg.role === "viewer" || msg.role === "agent" ? msg.role : undefined;
  const key = nonEmptyString(msg.apiKey);
  if (!role) {
    safeSend(ws, { type: "error", code: "invalid_hello", message: "Invalid connection request" });
    setTimeout(() => ws.close(1008, "invalid_hello"), 50);
    return;
  }
  if (!key || !usersByKey.has(key)) {
    safeSend(ws, { type: "error", code: "invalid_api_key", message: "Invalid API Key" });
    setTimeout(() => ws.close(1008, "invalid_api_key"), 50);
    return;
  }

  ws.data.role = role;
  ws.data.apiKey = key;
  ws.data.hostId = nonEmptyString(msg.hostId);
  ws.data.hostName = nonEmptyString(msg.hostName);

  if (role === "viewer") {
    viewerSet(key).add(ws);
  }

  const hostLabel = ws.data.hostName ?? ws.data.hostId ?? "unknown";
  const keyPreview = `${key.slice(0, 8)}…`;
  console.log(
    `[${new Date().toISOString()}] client connected role=${role} host=${hostLabel} apiKey=${keyPreview}`,
  );

  safeSend(ws, {
    type: "hello_ack",
    role,
    serverTime: new Date().toISOString(),
  });
}

async function relayEvent(input: {
  apiKey: string;
  requestId?: string;
  expectsResponse: boolean;
  hostId?: string;
  hostName?: string;
  payload: Record<string, unknown>;
  agent?: ServerWebSocket<ClientData>;
  abortSignal?: AbortSignal;
}): Promise<RelayResult> {
  const hostId = input.hostId ?? "unknown";
  const hostName = input.hostName ?? hostId;
  const requestId = input.requestId ?? randomUUID();
  const payload: Record<string, unknown> = { ...input.payload };
  payload._remote_host_id = nonEmptyString(payload._remote_host_id) ?? relayHostId(hostId);
  payload._remote_host_name = nonEmptyString(payload._remote_host_name) ?? hostName;

  const envelope = {
    type: "event",
    requestId,
    expectsResponse: input.expectsResponse,
    hostId,
    hostName,
    payload,
  };

  const viewers = viewersByKey.get(input.apiKey);
  if (!viewers || viewers.size === 0) {
    if (input.expectsResponse) {
      return { requestId, delivered: 0, payload: defaultResponse(payload) };
    }
    return { requestId, delivered: 0 };
  }

  let delivered = 0;
  for (const viewer of viewers) {
    safeSend(viewer, envelope);
    delivered += 1;
  }

  if (!input.expectsResponse) {
    return { requestId, delivered };
  }

  return await new Promise<RelayResult>((resolve) => {
    const timer = setTimeout(abortPending, requestTimeoutMs);
    let settled = false;

    function complete(
      result: RelayResult,
      notifyViewers = false,
      exclude?: ServerWebSocket<ClientData>,
    ) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      pendingRequests.delete(requestId);
      input.abortSignal?.removeEventListener("abort", abortPending);
      resolve(result);
      if (notifyViewers && result.payload) {
        broadcastResolved(input.apiKey, requestId, result.payload, exclude);
      }
    }

    function abortPending() {
      const responsePayload = defaultResponse(payload);
      complete({ requestId, delivered, payload: responsePayload, timedOut: true }, true);
    }

    if (input.abortSignal?.aborted) {
      abortPending();
      return;
    }
    input.abortSignal?.addEventListener("abort", abortPending, { once: true });

    pendingRequests.set(requestId, {
      apiKey: input.apiKey,
      delivered,
      timer,
      payload,
      complete,
      agent: input.agent,
    });
  });
}

async function handleAgentEvent(ws: ServerWebSocket<ClientData>, msg: Record<string, unknown>) {
  const key = ws.data.apiKey;
  if (ws.data.role !== "agent" || !key) {
    safeSend(ws, { type: "error", message: "agent hello required" });
    return;
  }

  if (!isRecord(msg.payload)) {
    safeSend(ws, { type: "error", message: "event payload must be an object" });
    return;
  }

  const expectsResponse = msg.expectsResponse === true;
  const result = await relayEvent({
    apiKey: key,
    requestId: nonEmptyString(msg.requestId),
    expectsResponse,
    hostId: nonEmptyString(msg.hostId) ?? ws.data.hostId,
    hostName: nonEmptyString(msg.hostName) ?? ws.data.hostName,
    payload: msg.payload,
    agent: ws,
  });

  if (expectsResponse) {
    safeSend(ws, {
      type: "response",
      requestId: result.requestId,
      payload: result.payload ?? defaultResponse(msg.payload),
      timedOut: result.timedOut,
    });
  } else {
    safeSend(ws, { type: "ack", requestId: result.requestId, delivered: result.delivered });
  }
}

function handleViewerResponse(ws: ServerWebSocket<ClientData>, msg: Record<string, unknown>) {
  const key = ws.data.apiKey;
  if (ws.data.role !== "viewer" || !key) {
    safeSend(ws, { type: "error", message: "viewer hello required" });
    return;
  }

  const requestId = nonEmptyString(msg.requestId);
  if (!requestId) {
    safeSend(ws, { type: "error", message: "response missing requestId" });
    return;
  }

  const pending = pendingRequests.get(requestId);
  if (!pending || pending.apiKey !== key) {
    safeSend(ws, { type: "ack", requestId, ignored: true });
    return;
  }

  const payload = isRecord(msg.payload) ? msg.payload : defaultResponse(pending.payload);
  pending.complete({ requestId, delivered: pending.delivered, payload }, true, ws);
  safeSend(ws, { type: "ack", requestId });
}

async function handleHttpEvent(request: Request) {
  const body = await request.json().catch(() => undefined);
  if (!isRecord(body)) {
    return jsonResponse({ error: "invalid_json" }, 400);
  }

  const key = nonEmptyString(body.apiKey) ?? bearerAPIKey(request);
  if (!key || !usersByKey.has(key)) {
    return jsonResponse({ error: "invalid_api_key", message: "Invalid API Key" }, 401);
  }

  if (!isRecord(body.payload)) {
    return jsonResponse({ error: "invalid_payload", message: "event payload must be an object" }, 400);
  }

  const result = await relayEvent({
    apiKey: key,
    requestId: nonEmptyString(body.requestId),
    expectsResponse: body.expectsResponse === true,
    hostId: nonEmptyString(body.hostId),
    hostName: nonEmptyString(body.hostName),
    payload: body.payload,
    abortSignal: request.signal,
  });

  return jsonResponse({
    ok: true,
    requestId: result.requestId,
    delivered: result.delivered,
    payload: result.payload,
    timedOut: result.timedOut,
  });
}

const server = Bun.serve<ClientData>({
  port,
  fetch: async (request, bunServer) => {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    if (request.method === "GET" && url.pathname === "/health") {
      return jsonResponse({
        ok: true,
        viewers: [...viewersByKey.values()].reduce((total, set) => total + set.size, 0),
        pending: pendingRequests.size,
      });
    }

    if (request.method === "GET" && url.pathname === "/resources/install.sh") {
      return resourceResponse("install.sh", "text/x-shellscript; charset=utf-8");
    }

    if (request.method === "GET" && url.pathname === "/resources/codeisland-relay-hook.py") {
      return resourceResponse("codeisland-relay-hook.py", "text/x-python; charset=utf-8");
    }

    if (request.method === "POST" && url.pathname === "/api/register") {
      const body = await request.json().catch(() => ({}));
      const user: StoredUser = {
        apiKey: apiKey(),
        createdAt: new Date().toISOString(),
        client: isRecord(body) ? nonEmptyString(body.client) : undefined,
        version: isRecord(body) ? nonEmptyString(body.version) : undefined,
      };
      saveUser(user);
      usersByKey.set(user.apiKey, user);
      return jsonResponse({ apiKey: user.apiKey });
    }

    if (request.method === "POST" && url.pathname === "/api/event") {
      return await handleHttpEvent(request);
    }

    if (request.method === "GET" && url.pathname === "/ws") {
      const upgraded = bunServer.upgrade(request, { data: {} });
      if (upgraded) return undefined;
      return new Response("upgrade failed", { status: 400 });
    }

    return jsonResponse({ error: "not_found" }, 404);
  },
  websocket: {
    message(ws, rawMessage) {
      const text = typeof rawMessage === "string"
        ? rawMessage
        : new TextDecoder().decode(rawMessage);
      let parsed: unknown;
      try {
        parsed = JSON.parse(text);
      } catch {
        safeSend(ws, { type: "error", message: "invalid json" });
        return;
      }
      if (!isRecord(parsed)) {
        safeSend(ws, { type: "error", message: "message must be an object" });
        return;
      }

      switch (parsed.type) {
        case "hello":
          handleHello(ws, parsed);
          break;
        case "event":
          void handleAgentEvent(ws, parsed);
          break;
        case "response":
          handleViewerResponse(ws, parsed);
          break;
        default:
          safeSend(ws, { type: "error", message: "unknown message type" });
          break;
      }
    },
    close(ws) {
      removeViewer(ws);
      cleanupAgentPending(ws);
    },
  },
});

console.log(`CodeIsland relay listening on http://localhost:${server.port}`);
console.log(`Database: ${dataFile}`);
