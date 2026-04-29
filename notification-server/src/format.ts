import type { WebhookPayload, NotificationData } from "./types";

const SOURCE_DISPLAY_NAMES: Record<string, string> = {
  claude: "Claude",
  codex: "Codex",
  gemini: "Gemini",
  cursor: "Cursor",
  copilot: "Copilot",
  trae: "Trae",
  kimi: "Kimi",
  qoder: "Qoder",
  qwen: "Qwen",
  opencode: "OpenCode",
  antigravity: "AntiGravity",
  codebuddy: "CodeBuddy",
  factory: "Factory",
  hermes: "Hermes",
  pi: "Pi",
  stepfun: "StepFun",
  workbuddy: "WorkBuddy",
};

const KNOWN_ICONS = new Set(Object.keys(SOURCE_DISPLAY_NAMES));

const EVENT_DISPLAY_NAMES: Record<string, string> = {
  SessionStart: "Session Started",
  SessionEnd: "Session Ended",
  UserPromptSubmit: "Prompt Submitted",
  PreToolUse: "Using Tool",
  PostToolUse: "Tool Completed",
  PostToolUseFailure: "Tool Failed",
  PermissionRequest: "Permission Request",
  SubagentStart: "Subagent Started",
  SubagentStop: "Subagent Stopped",
  PreCompact: "Compacting Context",
  PostCompact: "Context Compacted",
  Notification: "Notification",
  AfterAgentResponse: "Response",
  Stop: "Stopped",
};

function getSourceDisplayName(source: string): string {
  return SOURCE_DISPLAY_NAMES[source] || source || "CodeIsland";
}

function getIconFile(source: string): string {
  if (source && KNOWN_ICONS.has(source)) return `${source}.png`;
  return "default.png";
}

/** Shorten cwd to parent/folder, matching the app's subtitle format */
function shortCwd(cwd: string): string {
  if (!cwd) return "";
  const parts = cwd.split("/").filter(Boolean);
  if (parts.length >= 2) {
    let last = parts[parts.length - 1];
    // If last component is a numeric timestamp (e.g. CodeBuddy "20260406010126"),
    // show the parent directory name instead
    if (last.length >= 8 && /^\d+$/.test(last)) {
      last = parts[parts.length - 2];
    }
    return last;
  }
  return parts[parts.length - 1] || cwd;
}

/** Extract tool input from the raw payload, checking multiple key conventions */
function getToolInput(raw: Record<string, any>): Record<string, any> {
  return (
    raw.tool_input || raw.toolInput || raw.input || raw.arguments ||
    raw.payload?.input || raw.data?.input || {}
  );
}

/**
 * Build a tool description string, mirroring HookEvent.toolDescription
 * from Models.swift (lines 105-170).
 */
function extractToolDescription(payload: WebhookPayload): string | null {
  const toolName = payload.tool_name;
  if (!toolName) return null;

  const input = getToolInput(payload.raw);

  switch (toolName) {
    case "Bash": {
      if (input.description) return String(input.description);
      if (input.command) return `$ ${String(input.command).split("\n")[0].slice(0, 60)}`;
      return null;
    }
    case "Read": {
      const fp = input.file_path;
      if (!fp) return null;
      const name = String(fp).split("/").pop();
      return input.offset ? `${name}:${input.offset}` : name ?? null;
    }
    case "Edit":
    case "Write": {
      const fp = input.file_path;
      return fp ? String(fp).split("/").pop() ?? null : null;
    }
    case "Grep": {
      const pattern = input.pattern;
      if (!pattern) return null;
      const path = input.path ? ` in ${String(input.path).split("/").pop()}` : "";
      return `${pattern}${path}`;
    }
    case "Glob":
      return input.pattern ? String(input.pattern) : null;
    case "WebSearch":
      return input.query ? String(input.query) : null;
    case "WebFetch": {
      if (!input.url) return null;
      try { return new URL(String(input.url)).host; } catch { return String(input.url).slice(0, 40); }
    }
    case "Agent":
    case "Task":
      return input.description ? String(input.description).slice(0, 60) : input.prompt ? String(input.prompt).slice(0, 60) : null;
    case "TodoWrite":
      return "Updating tasks";
    default: {
      if (input.file_path) return String(input.file_path).split("/").pop() ?? null;
      if (input.pattern) return String(input.pattern);
      if (input.command) return String(input.command).slice(0, 60);
      if (input.prompt) return String(input.prompt).slice(0, 40);
      return null;
    }
  }
}

/** Try multiple keys in order, return the first non-empty string */
function firstString(obj: Record<string, any>, keys: string[]): string | null {
  for (const key of keys) {
    const val = obj[key];
    if (typeof val === "string" && val.trim()) return val.trim();
  }
  // Also check nested payload/data containers
  for (const container of ["payload", "data"]) {
    const nested = obj[container];
    if (nested && typeof nested === "object") {
      for (const key of keys) {
        const val = nested[key];
        if (typeof val === "string" && val.trim()) return val.trim();
      }
    }
  }
  return null;
}

/**
 * Extract body text per event type, mirroring the exact key lookups
 * in SessionSnapshot.reduceEvent() (SessionSnapshot.swift lines 534-708).
 */
function extractBody(payload: WebhookPayload): string | null {
  const raw = payload.raw;

  switch (payload.event) {
    case "Stop":
      // reduceEvent keys: last_assistant_message, text, message, summary
      return firstString(raw, ["last_assistant_message", "text", "message", "summary"]);

    case "AfterAgentResponse":
      // reduceEvent keys: text, message
      return firstString(raw, ["text", "message"]);

    case "UserPromptSubmit":
      // reduceEvent keys: prompt, user_prompt, message, input, content
      return firstString(raw, ["prompt", "user_prompt", "message", "input", "content"]);

    case "Notification":
      // reduceEvent keys: message, text, summary, status, detail
      return firstString(raw, ["message", "text", "summary", "status", "detail"]);

    case "SubagentStart":
      return typeof raw.agent_type === "string" ? raw.agent_type : null;

    default:
      return firstString(raw, ["message", "text", "summary", "status", "detail", "content"]);
  }
}

export function formatNotification(payload: WebhookPayload): NotificationData {
  const sourceName = getSourceDisplayName(payload.source);
  const eventLabel = EVENT_DISPLAY_NAMES[payload.event] || payload.event;
  const project = shortCwd(payload.cwd);

  // Title: Source · Event · ProjectFolder
  const titleParts = [sourceName, eventLabel];
  if (project) titleParts.push(project);
  const title = titleParts.join(" · ");

  // Body: event-specific content extraction, then tool description fallback
  const content = extractBody(payload);
  const toolDesc = extractToolDescription(payload);

  let body: string;

  switch (payload.event) {
    case "PreToolUse":
    case "PostToolUse":
    case "PostToolUseFailure":
      body = toolDesc
        ? `${payload.tool_name}: ${toolDesc}`
        : payload.tool_name || content || eventLabel;
      break;

    case "PermissionRequest":
      body = payload.tool_name
        ? `${payload.tool_name}${toolDesc ? ": " + toolDesc : ""}`
        : content || eventLabel;
      break;

    default:
      body = content || toolDesc || eventLabel;
      break;
  }

  return {
    title,
    body,
    group: sourceName,
    iconFile: getIconFile(payload.source),
  };
}
