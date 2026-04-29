#!/usr/bin/env python3
import argparse
import json
import os
import socket
import sys
import uuid
from urllib.parse import urlparse, urlunparse
from urllib.request import Request, urlopen

VERSION = "0.2.0"
DEFAULT_TIMEOUT_SECONDS = 300


def _normalize_event(name):
    if not isinstance(name, str):
        return ""
    aliases = {
        "sessionStart": "SessionStart",
        "sessionEnd": "SessionEnd",
        "userPromptSubmitted": "UserPromptSubmit",
        "preToolUse": "PreToolUse",
        "postToolUse": "PostToolUse",
        "errorOccurred": "Notification",
        "session_start": "SessionStart",
        "session_end": "SessionEnd",
        "user_prompt_submit": "UserPromptSubmit",
        "pre_tool_use": "PreToolUse",
        "post_tool_use": "PostToolUse",
        "post_tool_use_failure": "PostToolUseFailure",
        "permission_request": "PermissionRequest",
        "notification": "Notification",
        "subagent_start": "SubagentStart",
        "subagent_stop": "SubagentStop",
        "pre_compact": "PreCompact",
        "post_compact": "PostCompact",
        "beforeSubmitPrompt": "UserPromptSubmit",
        "beforeShellExecution": "PreToolUse",
        "afterShellExecution": "PostToolUse",
        "beforeReadFile": "PreToolUse",
        "afterFileEdit": "PostToolUse",
        "beforeMCPExecution": "PreToolUse",
        "afterMCPExecution": "PostToolUse",
        "afterAgentThought": "Notification",
        "afterAgentResponse": "AfterAgentResponse",
        "stop": "Stop",
        "BeforeTool": "PreToolUse",
        "AfterTool": "PostToolUse",
        "BeforeAgent": "SubagentStart",
        "AfterAgent": "SubagentStop",
    }
    return aliases.get(name, name)


def _event_name(payload):
    return (
        payload.get("hook_event_name")
        or payload.get("hookEventName")
        or payload.get("event_name")
        or payload.get("eventName")
        or payload.get("event")
        or ""
    )


def _default_response(payload):
    event = _normalize_event(_event_name(payload))
    if event == "PermissionRequest":
        return {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "deny"},
            }
        }
    if event == "Notification":
        return {"hookSpecificOutput": {"hookEventName": "Notification"}}
    return {}


def _expects_response(payload):
    event = _normalize_event(_event_name(payload))
    return event == "PermissionRequest" or (event == "Notification" and bool(payload.get("question")))


def _read_stdin_json():
    try:
        return json.load(sys.stdin)
    except Exception:
        return None


def _load_config(path):
    if not path:
        path = os.environ.get("CODEISLAND_RELAY_CONFIG", "~/.codeisland/relay.json")
    path = os.path.expanduser(path)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
            return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _first(*values):
    for value in values:
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def _server_event_url(raw):
    if not raw:
        return None
    raw = raw.strip()
    if "://" not in raw:
        raw = "https://" + raw
    parsed = urlparse(raw)
    scheme_map = {
        "http": "http",
        "https": "https",
        "ws": "http",
        "wss": "https",
    }
    scheme = scheme_map.get(parsed.scheme)
    if not scheme or not parsed.netloc:
        return None
    base_path = parsed.path.rstrip("/")
    return urlunparse((scheme, parsed.netloc, base_path + "/api/event", "", "", ""))


def _post_event(url, api_key, body, timeout):
    data = json.dumps(body, separators=(",", ":")).encode("utf-8")
    request = Request(
        url,
        data=data,
        headers={
            "Authorization": "Bearer " + api_key,
            "Content-Type": "application/json",
            "User-Agent": "CodeIsland-Relay-Hook/" + VERSION,
        },
        method="POST",
    )
    with urlopen(request, timeout=timeout) as response:
        raw = response.read()
    if not raw:
        return {}
    parsed = json.loads(raw.decode("utf-8"))
    return parsed if isinstance(parsed, dict) else {}


def main():
    parser = argparse.ArgumentParser(description="Forward CodeIsland hook events through a forwarding server.")
    parser.add_argument("--server")
    parser.add_argument("--api-key")
    parser.add_argument("--host-id")
    parser.add_argument("--host-name")
    parser.add_argument("--source")
    parser.add_argument("--config")
    parser.add_argument("--event")
    parser.add_argument("--timeout", type=float, default=None)
    parser.add_argument("--version", action="store_true")
    args = parser.parse_args()

    if args.version:
        print(VERSION)
        return 0

    config = _load_config(args.config)
    server = _first(args.server, os.environ.get("CODEISLAND_RELAY_SERVER"), config.get("serverUrl"), config.get("server_url"))
    api_key = _first(args.api_key, os.environ.get("CODEISLAND_RELAY_API_KEY"), config.get("apiKey"), config.get("api_key"))
    host_id = _first(args.host_id, os.environ.get("CODEISLAND_REMOTE_HOST_ID"), config.get("hostId"), config.get("host_id"), socket.gethostname())
    host_name = _first(args.host_name, os.environ.get("CODEISLAND_REMOTE_HOST_NAME"), config.get("hostName"), config.get("host_name"), host_id)
    source = _first(args.source, os.environ.get("CODEISLAND_SOURCE"), config.get("source"))
    timeout = args.timeout or float(config.get("timeout", DEFAULT_TIMEOUT_SECONDS))

    payload = _read_stdin_json()
    if not isinstance(payload, dict):
        return 1
    if args.event and not payload.get("hook_event_name"):
        payload["hook_event_name"] = args.event
    if source and not payload.get("_source"):
        payload["_source"] = source
    if not payload.get("cwd"):
        payload["cwd"] = os.getcwd()

    event_name = _event_name(payload)
    session_id = payload.get("session_id") or payload.get("sessionId")
    if not event_name or not session_id:
        return 1

    expects_response = _expects_response(payload)
    event_url = _server_event_url(server)
    if not event_url or not api_key:
        if expects_response:
            print(json.dumps(_default_response(payload), separators=(",", ":")))
        return 0

    request_id = str(uuid.uuid4())
    body = {
        "requestId": request_id,
        "expectsResponse": expects_response,
        "hostId": host_id,
        "hostName": host_name,
        "payload": payload,
    }

    try:
        response = _post_event(event_url, api_key, body, timeout)
        response_payload = response.get("payload")
        if expects_response:
            if not isinstance(response_payload, dict):
                response_payload = _default_response(payload)
            print(json.dumps(response_payload, separators=(",", ":")))
        return 0
    except Exception:
        if expects_response:
            print(json.dumps(_default_response(payload), separators=(",", ":")))
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
