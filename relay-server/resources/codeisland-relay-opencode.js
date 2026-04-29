// codeisland-relay-opencode — OpenCode plugin for CodeIsland relay
// Forwards OpenCode events to a CodeIsland relay server via HTTP.
// Installed by install.sh; config read from ~/.codeisland/relay.json.
import { readFileSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { randomUUID } from "crypto";

const CONFIG_PATH = process.env.CODEISLAND_RELAY_CONFIG
  || join(homedir(), ".codeisland", "relay.json");
const DEFAULT_TIMEOUT_MS = 300000;

function loadConfig() {
  try {
    return JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));
  } catch { return {}; }
}

function eventUrl(raw) {
  if (!raw) return null;
  raw = raw.trim();
  if (!raw.includes("://")) raw = "https://" + raw;
  try {
    const u = new URL(raw);
    if (u.protocol === "ws:") u.protocol = "http:";
    if (u.protocol === "wss:") u.protocol = "https:";
    u.pathname = u.pathname.replace(/\/+$/, "") + "/api/event";
    return u.toString();
  } catch { return null; }
}

function postEvent(url, apiKey, body, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  return fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${apiKey}`,
      "User-Agent": "CodeIsland-Relay-OpenCode/1.0",
    },
    body: JSON.stringify(body),
    signal: controller.signal,
  }).then(r => r.json()).catch(() => ({})).finally(() => clearTimeout(timer));
}

export default {
  id: "codeisland-relay",
  server: async ({ client, serverUrl }) => {
    const config = loadConfig();
    const relayUrl = process.env.CODEISLAND_RELAY_SERVER || config.serverUrl || config.server_url;
    const apiKey = process.env.CODEISLAND_RELAY_API_KEY || config.apiKey || config.api_key;
    const hostId = process.env.CODEISLAND_REMOTE_HOST_ID || config.hostId || config.host_id;
    const hostName = process.env.CODEISLAND_REMOTE_HOST_NAME || config.hostName || config.host_name || hostId;
    const url = eventUrl(relayUrl);

    if (!url || !apiKey) {
      console.error("[codeisland-relay] Missing relay server URL or API key in", CONFIG_PATH);
    }

    const openCodePort = serverUrl ? parseInt(serverUrl.port) || 4096 : 4096;
    const heyApi = client?._client;
    const msgRoles = new Map();
    const sessions = new Map();
    const sessionCwd = new Map();
    const pendingRequestSessions = new Set();

    function getSession(sid) {
      if (!sessions.has(sid)) sessions.set(sid, { lastUserText: "", lastAssistantText: "" });
      return sessions.get(sid);
    }

    function base(sessionId, extra) {
      return {
        session_id: sessionId,
        _source: "opencode",
        _remote_host_id: hostId,
        _remote_host_name: hostName,
        ...extra,
      };
    }

    async function sendFireAndForget(payload) {
      if (!url || !apiKey) return;
      await postEvent(url, apiKey, {
        requestId: randomUUID(),
        expectsResponse: false,
        hostId, hostName,
        payload,
      }, 5000);
    }

    async function sendAndWaitResponse(payload) {
      if (!url || !apiKey) return null;
      const resp = await postEvent(url, apiKey, {
        requestId: randomUUID(),
        expectsResponse: true,
        hostId, hostName,
        payload,
      }, DEFAULT_TIMEOUT_MS);
      return resp?.payload ?? null;
    }

    // --- Event mapping (same as local plugin) ---

    function mapEvent(ev) {
      const t = ev.type;
      const p = ev.properties || {};

      if (t === "session.created" && p.info) {
        const cwd = p.info.directory || "";
        sessionCwd.set(p.info.id, cwd);
        return base(`opencode-${p.info.id}`, { hook_event_name: "SessionStart", cwd });
      }
      if (t === "session.deleted" && p.info) {
        sessions.delete(p.info.id); sessionCwd.delete(p.info.id);
        return base(`opencode-${p.info.id}`, { hook_event_name: "SessionEnd" });
      }
      if (t === "session.updated" && p.info) {
        if (p.info.directory) sessionCwd.set(p.info.id, p.info.directory);
        if (p.info.time?.archived) {
          sessions.delete(p.info.id); sessionCwd.delete(p.info.id);
          return base(`opencode-${p.info.id}`, { hook_event_name: "SessionEnd" });
        }
        if (p.info.title && !p.info.title.startsWith("New session")) {
          getSession(p.info.id).pendingTitle = p.info.title;
        }
        return null;
      }
      if (t === "session.status" && p.sessionID) {
        const sid = `opencode-${p.sessionID}`;
        const s = getSession(p.sessionID);
        const cwd = sessionCwd.get(p.sessionID);
        if (p.status?.type === "idle") {
          const extra = { hook_event_name: "Stop", cwd,
            last_assistant_message: s.lastAssistantText || undefined };
          if (s.pendingTitle) { extra.codex_title = s.pendingTitle; s.pendingTitle = null; }
          return base(sid, extra);
        }
      }
      if (t === "message.updated" && p.info?.id && p.info?.sessionID) {
        msgRoles.set(p.info.id, { role: p.info.role, sessionID: p.info.sessionID });
        if (msgRoles.size > 200) { msgRoles.delete(msgRoles.keys().next().value); }
        return null;
      }
      if (t === "message.part.updated" && p.part?.type === "text" && p.part?.messageID) {
        const meta = msgRoles.get(p.part.messageID);
        if (!meta) return null;
        const s = getSession(meta.sessionID);
        const cwd = sessionCwd.get(meta.sessionID);
        const text = p.part.text || "";
        if (meta.role === "user" && text) {
          s.lastUserText = text;
          return base(`opencode-${meta.sessionID}`, {
            hook_event_name: "UserPromptSubmit", cwd, prompt: text });
        }
        if (meta.role === "assistant" && text) { s.lastAssistantText = text; }
        return null;
      }
      if (t === "message.part.updated" && p.part?.type === "tool" && p.part?.sessionID) {
        const sid = `opencode-${p.part.sessionID}`;
        const st = p.part.state?.status;
        const cwd = sessionCwd.get(p.part.sessionID);
        const toolName = (p.part.tool || "").charAt(0).toUpperCase() + (p.part.tool || "").slice(1);
        if (st === "running" || st === "pending") {
          return base(sid, { hook_event_name: "PreToolUse", cwd, tool_name: toolName,
            tool_input: p.part.state?.input || {} });
        }
        if (st === "completed" || st === "error") {
          return base(sid, { hook_event_name: "PostToolUse", cwd, tool_name: toolName });
        }
      }
      if (t === "permission.asked" && p.id && p.sessionID) {
        const toolName = (p.permission || "").charAt(0).toUpperCase() + (p.permission || "").slice(1);
        const patterns = p.patterns || [];
        const toolInput = { patterns, metadata: p.metadata };
        if (p.permission === "bash" && patterns.length > 0) {
          toolInput.command = patterns.join(" && ");
        }
        if ((p.permission === "edit" || p.permission === "write") && patterns.length > 0) {
          toolInput.file_path = patterns[0];
        }
        return base(`opencode-${p.sessionID}`, { hook_event_name: "PermissionRequest",
          cwd: sessionCwd.get(p.sessionID), tool_name: toolName,
          tool_input: toolInput, _opencode_request_id: p.id });
      }
      if (t === "permission.replied" && p.sessionID) {
        return base(`opencode-${p.sessionID}`, { hook_event_name: "PostToolUse",
          cwd: sessionCwd.get(p.sessionID) });
      }
      if (t === "question.asked" && p.id && p.sessionID) {
        const questions = (p.questions || []).map(q => ({
          question: q.question || "",
          header: q.header || "",
          options: (q.options || []).map(o => ({ label: o.label, description: o.description })),
          multiSelect: q.multiple || false,
        }));
        return base(`opencode-${p.sessionID}`, { hook_event_name: "PermissionRequest",
          cwd: sessionCwd.get(p.sessionID), tool_name: "AskUserQuestion",
          tool_input: { questions }, _opencode_request_id: p.id });
      }
      if ((t === "question.replied" || t === "question.rejected") && p.sessionID) {
        return base(`opencode-${p.sessionID}`, { hook_event_name: "PostToolUse",
          cwd: sessionCwd.get(p.sessionID) });
      }
      return null;
    }

    // --- OpenCode reply functions (same as local plugin) ---

    async function replyQuestion(requestId, answers) {
      try {
        if (typeof heyApi?.request === "function") {
          await heyApi.request({ method: "POST", url: "/question/{requestID}/reply",
            path: { requestID: requestId }, body: { answers } });
          return;
        }
      } catch {}
      try {
        await fetch(`http://localhost:${openCodePort}/question/${requestId}/reply`, {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ answers }),
        });
      } catch {}
    }

    async function rejectQuestion(requestId) {
      try {
        if (typeof heyApi?.request === "function") {
          await heyApi.request({ method: "POST", url: "/question/{requestID}/reject",
            path: { requestID: requestId } });
          return;
        }
      } catch {}
      try {
        await fetch(`http://localhost:${openCodePort}/question/${requestId}/reject`, {
          method: "POST", headers: { "Content-Type": "application/json" },
        });
      } catch {}
    }

    async function replyPermission(requestId, reply, reason) {
      try {
        if (typeof heyApi?.request === "function") {
          await heyApi.request({ method: "POST", url: "/permission/{requestID}/reply",
            path: { requestID: requestId }, body: { reply, message: reason } });
          return;
        }
      } catch {}
      try {
        await fetch(`http://localhost:${openCodePort}/permission/${requestId}/reply`, {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ reply, message: reason }),
        });
      } catch {}
    }

    async function handlePermissionReply(mapped) {
      const requestId = mapped._opencode_request_id;
      pendingRequestSessions.add(mapped.session_id);
      let response;
      try {
        response = await sendAndWaitResponse(mapped);
      } finally {
        pendingRequestSessions.delete(mapped.session_id);
      }
      if (!response) return;
      const behavior = response?.hookSpecificOutput?.decision?.behavior;
      const reason = response?.hookSpecificOutput?.decision?.reason;
      if (!behavior) return;
      const hasUpdatedPerms = response?.hookSpecificOutput?.decision?.updatedPermissions != null;
      const reply = (behavior === "always" || (behavior === "allow" && hasUpdatedPerms)) ? "always"
        : behavior === "allow" ? "once" : "reject";
      await replyPermission(requestId, reply, reason);
    }

    async function handleQuestionReply(mapped) {
      const requestId = mapped._opencode_request_id;
      pendingRequestSessions.add(mapped.session_id);
      let response;
      try {
        response = await sendAndWaitResponse(mapped);
      } finally {
        pendingRequestSessions.delete(mapped.session_id);
      }
      if (!response) return;
      const decision = response?.hookSpecificOutput?.decision;
      if (!decision) return;
      if (decision.behavior === "deny") {
        await rejectQuestion(requestId);
        return;
      }
      const answers = decision?.updatedInput?.answers;
      if (!answers) return;
      const answerArray = Object.values(answers).map(v => [v]);
      await replyQuestion(requestId, answerArray);
    }

    // --- Event handler ---

    return {
      "event": async ({ event }) => {
        const isReplyEvent = event.type === "permission.replied"
          || event.type === "question.replied"
          || event.type === "question.rejected";

        const mapped = mapEvent(event);
        if (!mapped) return;

        if (mapped.hook_event_name === "PermissionRequest" && mapped.tool_name === "AskUserQuestion") {
          handleQuestionReply(mapped).catch(() => {});
          return;
        }
        if (mapped.hook_event_name === "PermissionRequest") {
          handlePermissionReply(mapped).catch(() => {});
          return;
        }
        if (!isReplyEvent
            && pendingRequestSessions.has(mapped.session_id)
            && mapped.hook_event_name !== "SessionStart"
            && mapped.hook_event_name !== "SessionEnd") {
          return;
        }
        await sendFireAndForget(mapped);
      },
    };
  },
};
