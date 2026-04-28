#!/bin/sh
set -eu

SERVER_URL="${CODEISLAND_RELAY_SERVER:-}"
API_KEY="${CODEISLAND_RELAY_API_KEY:-}"

if [ -z "$SERVER_URL" ] || [ -z "$API_KEY" ]; then
  echo "Missing CODEISLAND_RELAY_SERVER or CODEISLAND_RELAY_API_KEY." >&2
  echo "Use the install command copied from CodeIsland settings." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to install CodeIsland remote hooks." >&2
  exit 1
fi

BASE_URL="${SERVER_URL%/}"
INSTALL_DIR="${CODEISLAND_RELAY_HOME:-$HOME/.codeisland}"
CONFIG_PATH="$INSTALL_DIR/relay.json"
HOOK_PATH="$INSTALL_DIR/codeisland-relay-hook.py"
HOST_DEFAULT="$(hostname 2>/dev/null || printf 'remote')"

HOST_NAME=""
if [ -r /dev/tty ]; then
  printf "Remote display name [%s]: " "$HOST_DEFAULT" > /dev/tty
  IFS= read -r HOST_NAME < /dev/tty || HOST_NAME=""
fi
if [ -z "$HOST_NAME" ]; then
  HOST_NAME="$HOST_DEFAULT"
fi

mkdir -p "$INSTALL_DIR"

download() {
  url="$1"
  dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
  else
    echo "curl or wget is required to download CodeIsland hook resources." >&2
    exit 1
  fi
}

download "$BASE_URL/resources/codeisland-relay-hook.py" "$HOOK_PATH"
chmod 755 "$HOOK_PATH"

python3 - "$CONFIG_PATH" "$SERVER_URL" "$API_KEY" "$HOST_NAME" "$HOOK_PATH" <<'PY'
import json
import os
import pathlib
import shlex
import shutil
import sys
import uuid

config_path = pathlib.Path(sys.argv[1]).expanduser()
server_url = sys.argv[2]
api_key = sys.argv[3]
host_name = sys.argv[4]
hook_path = pathlib.Path(sys.argv[5]).expanduser()
home = pathlib.Path.home()

def load_json(path):
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}

existing_config = load_json(config_path)
host_id = existing_config.get("hostId") or existing_config.get("host_id")
if not isinstance(host_id, str) or not host_id.strip():
    safe_name = "".join(ch if ch.isalnum() or ch in "-_" else "-" for ch in host_name.lower()).strip("-")
    host_id = f"{safe_name or 'remote'}-{uuid.uuid4().hex[:8]}"

config = {
    "serverUrl": server_url,
    "apiKey": api_key,
    "hostId": host_id,
    "hostName": host_name,
}
config_path.parent.mkdir(parents=True, exist_ok=True)
config_path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n", encoding="utf-8")
os.chmod(config_path, 0o600)

def _codex_home():
    raw = os.environ.get("CODEX_HOME", "").strip()
    return pathlib.Path(os.path.expanduser(raw)) if raw else home / ".codex"

def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")

def command_for(source):
    return (
        f"python3 {shlex.quote(str(hook_path))} "
        f"--config {shlex.quote(str(config_path))} "
        f"--source {shlex.quote(source)}"
    )

def command_matches(cmd):
    return isinstance(cmd, str) and "codeisland-relay-hook.py" in cmd

def remove_managed_hooks(hooks):
    if not isinstance(hooks, dict):
        return {}
    for event in list(hooks.keys()):
        entries = hooks.get(event)
        if not isinstance(entries, list):
            continue
        kept = []
        for entry in entries:
            if not isinstance(entry, dict):
                kept.append(entry)
                continue
            commands = []
            if isinstance(entry.get("command"), str):
                commands.append(entry["command"])
            if isinstance(entry.get("bash"), str):
                commands.append(entry["bash"])
            if isinstance(entry.get("hooks"), list):
                for item in entry["hooks"]:
                    if isinstance(item, dict) and isinstance(item.get("command"), str):
                        commands.append(item["command"])
            if any(command_matches(cmd) for cmd in commands):
                continue
            kept.append(entry)
        if kept:
            hooks[event] = kept
        else:
            hooks.pop(event, None)
    return hooks

def nested_entry(cmd, timeout, matcher=None):
    hook = {"type": "command", "command": cmd, "timeout": timeout}
    entry = {"hooks": [hook]}
    if matcher is not None:
        entry["matcher"] = matcher
    return [entry]

def install_json_hooks(name, source, path, events, requires_binary=None):
    if not path.parent.exists() and requires_binary and shutil.which(requires_binary) is None:
        return f"{name} skipped"
    data = load_json(path)
    hooks = remove_managed_hooks(data.get("hooks") or {})
    cmd = command_for(source)
    for event, timeout, matcher in events:
        hooks[event] = nested_entry(cmd, timeout, matcher)
    data["hooks"] = hooks
    write_json(path, data)
    return f"{name} ok"

def ensure_codex_hooks_enabled(path):
    content = path.read_text(encoding="utf-8") if path.exists() else ""
    if "codex_hooks = true" in content:
        return
    lines = content.splitlines()
    try:
        idx = next(i for i, line in enumerate(lines) if line.strip() == "[features]")
        lines.insert(idx + 1, "codex_hooks = true")
    except StopIteration:
        if lines and lines[-1].strip():
            lines.append("")
        lines.extend(["[features]", "codex_hooks = true"])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")

def install_codex():
    root = _codex_home()
    if not root.exists() and shutil.which("codex") is None:
        return "Codex skipped"
    result = install_json_hooks(
        "Codex",
        "codex",
        root / "hooks.json",
        [
            ("SessionStart", 5, None),
            ("SessionEnd", 5, None),
            ("UserPromptSubmit", 5, None),
            ("PreToolUse", 5, None),
            ("PostToolUse", 5, None),
            ("Stop", 5, None),
        ],
    )
    ensure_codex_hooks_enabled(root / "config.toml")
    return result

def install_traecli():
    root = home / ".trae"
    if not root.exists() and shutil.which("traecli") is None:
        return "Traecli skipped"
    path = root / "traecli.yaml"
    content = path.read_text(encoding="utf-8") if path.exists() else ""
    lines = content.replace("\r\n", "\n").split("\n")
    cleaned = []
    skipping = False
    for line in lines:
        if line.strip() == "# CodeIsland relay hooks begin":
            skipping = True
            continue
        if line.strip() == "# CodeIsland relay hooks end":
            skipping = False
            continue
        if not skipping:
            cleaned.append(line)
    content = "\n".join(cleaned).rstrip()
    if "hooks:" not in [line.strip() for line in cleaned]:
        content = (content + "\n\n" if content else "") + "hooks:"
    cmd = command_for("traecli").replace("'", "''")
    events = [
        "session_start",
        "session_end",
        "user_prompt_submit",
        "pre_tool_use",
        "post_tool_use",
        "post_tool_use_failure",
        "permission_request",
        "notification",
        "subagent_start",
        "subagent_stop",
        "stop",
        "pre_compact",
        "post_compact",
    ]
    block = [
        "  # CodeIsland relay hooks begin",
        "  - type: command",
        f"    command: '{cmd}'",
        "    timeout: '86400s'",
        "    matchers:",
    ]
    block.extend([f"      - event: {event}" for event in events])
    block.append("  # CodeIsland relay hooks end")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content + "\n" + "\n".join(block) + "\n", encoding="utf-8")
    return "Traecli ok"

results = []
results.append(install_json_hooks(
    "Claude",
    "claude",
    home / ".claude" / "settings.json",
    [
        ("UserPromptSubmit", 5, None),
        ("PreToolUse", 5, None),
        ("PostToolUse", 5, None),
        ("PostToolUseFailure", 5, None),
        ("PermissionRequest", 86400, "*"),
        ("Notification", 86400, "*"),
        ("Stop", 5, None),
        ("SubagentStart", 5, None),
        ("SubagentStop", 5, None),
        ("SessionStart", 5, None),
        ("SessionEnd", 5, None),
        ("PreCompact", 5, "auto"),
    ],
    requires_binary="claude",
))
results.append(install_codex())
results.append(install_json_hooks(
    "CodeBuddy",
    "codebuddy",
    home / ".codebuddy" / "settings.json",
    [
        ("UserPromptSubmit", 5, None),
        ("PermissionRequest", 86400, "*"),
        ("Notification", 86400, "*"),
        ("Stop", 5, None),
        ("SessionStart", 5, None),
        ("SessionEnd", 5, None),
        ("PreCompact", 5, "auto"),
    ],
    requires_binary="codebuddy",
))
results.append(install_json_hooks(
    "Gemini",
    "gemini",
    home / ".gemini" / "settings.json",
    [
        ("SessionStart", 10000, None),
        ("SessionEnd", 10000, None),
        ("BeforeTool", 10000, None),
        ("AfterTool", 10000, None),
        ("BeforeAgent", 10000, None),
        ("AfterAgent", 10000, None),
    ],
    requires_binary="gemini",
))
results.append(install_traecli())

print("Config:", config_path)
print("Hook:", hook_path)
print("Host:", host_name, f"({host_id})")
print("Hooks:", " · ".join(results))
PY

echo
echo "CodeIsland remote hooks installed."
echo "Config file: $CONFIG_PATH"
echo "Hook file: $HOOK_PATH"
