#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import os
import socket
import ssl
import struct
import sys
import time
import uuid
from urllib.parse import urlparse, urlunparse

VERSION = "0.1.0"
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


def _default_response(payload):
    event = _normalize_event(
        payload.get("hook_event_name")
        or payload.get("hookEventName")
        or payload.get("event_name")
        or payload.get("eventName")
        or ""
    )
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
    event = _normalize_event(
        payload.get("hook_event_name")
        or payload.get("hookEventName")
        or payload.get("event")
        or ""
    )
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


def _server_ws_url(raw):
    if not raw:
        return None
    raw = raw.strip()
    if "://" not in raw:
        raw = "https://" + raw
    parsed = urlparse(raw)
    scheme_map = {
        "http": "ws",
        "https": "wss",
        "ws": "ws",
        "wss": "wss",
    }
    scheme = scheme_map.get(parsed.scheme)
    if not scheme or not parsed.netloc:
        return None
    return urlunparse((scheme, parsed.netloc, "/ws", "", "", ""))


def _read_exact(sock, n):
    chunks = []
    remaining = n
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            raise OSError("connection closed")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _send_frame(sock, payload, opcode=0x1):
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    length = len(payload)
    header = bytearray([0x80 | opcode])
    if length < 126:
        header.append(0x80 | length)
    elif length < 65536:
        header.append(0x80 | 126)
        header.extend(struct.pack("!H", length))
    else:
        header.append(0x80 | 127)
        header.extend(struct.pack("!Q", length))
    mask = os.urandom(4)
    header.extend(mask)
    masked = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))
    sock.sendall(bytes(header) + masked)


def _recv_frame(sock):
    b1, b2 = _read_exact(sock, 2)
    opcode = b1 & 0x0F
    masked = bool(b2 & 0x80)
    length = b2 & 0x7F
    if length == 126:
        length = struct.unpack("!H", _read_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", _read_exact(sock, 8))[0]
    mask = _read_exact(sock, 4) if masked else b""
    payload = _read_exact(sock, length) if length else b""
    if masked:
        payload = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload))

    if opcode == 0x8:
        return None
    if opcode == 0x9:
        _send_frame(sock, payload, opcode=0xA)
        return _recv_frame(sock)
    if opcode == 0xA:
        return _recv_frame(sock)
    if opcode != 0x1:
        return _recv_frame(sock)
    return payload.decode("utf-8")


def _connect_websocket(url, timeout):
    parsed = urlparse(url)
    secure = parsed.scheme == "wss"
    host = parsed.hostname
    if not host:
        raise OSError("missing host")
    port = parsed.port or (443 if secure else 80)
    path = parsed.path or "/ws"
    if parsed.query:
        path += "?" + parsed.query

    raw_sock = socket.create_connection((host, port), timeout=timeout)
    raw_sock.settimeout(timeout)
    sock = ssl.create_default_context().wrap_socket(raw_sock, server_hostname=host) if secure else raw_sock

    key = base64.b64encode(os.urandom(16)).decode("ascii")
    host_header = parsed.netloc
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host_header}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "User-Agent: CodeIsland-Relay-Hook/0.1\r\n"
        "\r\n"
    )
    sock.sendall(request.encode("ascii"))
    response = b""
    while b"\r\n\r\n" not in response:
        response += sock.recv(4096)
        if len(response) > 65536:
            raise OSError("handshake too large")
    header_text = response.decode("iso-8859-1", errors="replace")
    if " 101 " not in header_text.split("\r\n", 1)[0]:
        raise OSError("websocket upgrade failed")
    expected_accept = base64.b64encode(
        hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
    ).decode("ascii")
    if expected_accept not in header_text:
        raise OSError("websocket accept mismatch")
    return sock


def _send_json(sock, obj):
    _send_frame(sock, json.dumps(obj, separators=(",", ":")))


def _recv_json(sock, timeout_at):
    while True:
        if time.monotonic() > timeout_at:
            raise TimeoutError("timed out waiting for relay")
        text = _recv_frame(sock)
        if text is None:
            raise OSError("connection closed")
        try:
            msg = json.loads(text)
        except Exception:
            continue
        if isinstance(msg, dict):
            return msg


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

    event_name = payload.get("hook_event_name") or payload.get("hookEventName") or payload.get("event")
    session_id = payload.get("session_id") or payload.get("sessionId")
    if not event_name or not session_id:
        return 1

    expects_response = _expects_response(payload)
    ws_url = _server_ws_url(server)
    if not ws_url or not api_key:
        if expects_response:
            print(json.dumps(_default_response(payload), separators=(",", ":")))
            return 0
        return 0

    request_id = str(uuid.uuid4())
    timeout_at = time.monotonic() + timeout
    sock = None
    try:
        sock = _connect_websocket(ws_url, timeout=min(timeout, 30))
        _send_json(sock, {
            "type": "hello",
            "role": "agent",
            "apiKey": api_key,
            "hostId": host_id,
            "hostName": host_name,
            "protocolVersion": 1,
        })
        hello = _recv_json(sock, timeout_at)
        if hello.get("type") == "error":
            raise OSError(str(hello.get("message") or "relay rejected hello"))

        _send_json(sock, {
            "type": "event",
            "requestId": request_id,
            "expectsResponse": expects_response,
            "hostId": host_id,
            "hostName": host_name,
            "payload": payload,
        })

        while True:
            msg = _recv_json(sock, timeout_at)
            msg_type = msg.get("type")
            if msg_type == "ack" and not expects_response:
                return 0
            if msg_type == "response" and msg.get("requestId") == request_id:
                response_payload = msg.get("payload")
                if not isinstance(response_payload, dict):
                    response_payload = _default_response(payload)
                if expects_response:
                    print(json.dumps(response_payload, separators=(",", ":")))
                return 0
    except Exception:
        if expects_response:
            print(json.dumps(_default_response(payload), separators=(",", ":")))
        return 0
    finally:
        if sock is not None:
            try:
                _send_frame(sock, b"", opcode=0x8)
                sock.close()
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
