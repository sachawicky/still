#!/usr/bin/env python3
"""Merge passive Still hooks without touching trust, policies, MCP or existing hooks.
Dry-run by default. --apply writes mode-600 backups before an atomic replacement.
"""
import argparse
import copy
import datetime
import json
import os
from pathlib import Path
import shlex
import tempfile


def additions(provider, executable, user_approvals=False):
    command = shlex.quote(str(executable)) + " --focus-hook " + provider
    events = {"SessionStart": [{"hooks": [{"type": "command", "command": command, "timeout": 3}]}]}
    if provider == "claude":
        events["Notification"] = [{
            "matcher": "^(permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input)$",
            "hooks": [{"type": "command", "command": command, "timeout": 3}]}]
    else:
        events["PreToolUse"] = [{"matcher": "^request_user_input$", "hooks": [
            {"type": "command", "command": command, "timeout": 3}]}]
    if provider == "codex" and user_approvals:
        events["PermissionRequest"] = [{"hooks": [{"type": "command", "command": command + " --user-approvals", "timeout": 3}]}]
    return events


def merge(original, extra):
    result = copy.deepcopy(original)
    hooks = result.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("Existing hooks must be an object; refusing to overwrite")
    for event, entries in extra.items():
        current = hooks.setdefault(event, [])
        if not isinstance(current, list):
            raise ValueError("Existing hook event must be an array")
        for entry in entries:
            if entry not in current:
                current.append(entry)
    return result


def install(path, extra, apply):
    if path.is_symlink():
        raise ValueError("Refusing symlink configuration")
    old = path.read_bytes() if path.exists() else None
    original = json.loads(old) if old is not None else {}
    if not isinstance(original, dict):
        raise ValueError("Existing configuration must be an object")
    result = merge(original, extra)
    if result == original:
        print(f"Unchanged: {path}")
        return
    print(f"{'Merging' if apply else 'Would merge'}: {path}")
    if not apply:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if old is not None:
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        backup = path.with_name(path.name + ".still-backup-" + stamp)
        fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(old)
            stream.flush()
            os.fsync(stream.fileno())
        print(f"Backup: {backup}")
    fd, temporary = tempfile.mkstemp(prefix=".still-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(result, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        # Do not overwrite an edit made after our read.
        current = path.read_bytes() if path.exists() else None
        if current != old:
            raise RuntimeError("Configuration changed during merge; retry")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--provider", choices=["claude", "codex", "both"], default="both")
    parser.add_argument("--codex-user-approvals", action="store_true", help="Only for user-routed approvals; never auto_review")
    parser.add_argument("--config-root", type=Path, default=Path.home())
    parser.add_argument("--executable", type=Path, default=Path("/Applications/Still.app/Contents/MacOS/Still"))
    args = parser.parse_args()
    if not args.executable.is_file():
        parser.error("Install Still before configuring hooks")
    providers = ["claude", "codex"] if args.provider == "both" else [args.provider]
    for provider in providers:
        path = args.config_root / (".claude/settings.json" if provider == "claude" else ".codex/hooks.json")
        install(path, additions(provider, args.executable, args.codex_user_approvals), args.apply)
    print("Restart agent sessions. Review/trust Codex hooks with /hooks; this script never changes hook trust.")
    if "codex" in providers and not args.codex_user_approvals:
        print("Codex: session-start and explicit question tool hooks. Permission alerts OFF because auto-review cannot be distinguished by the hook.")


if __name__ == "__main__":
    main()
