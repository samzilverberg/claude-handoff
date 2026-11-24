#!/usr/bin/env python3
"""Trust the handoff plugin's Codex hooks (run after every install or upgrade of the plugin).

Codex runs a non-managed hook only after it was reviewed: config.toml [hooks.state."<key>"] trusted_hash must equal
the hook's current hash, which covers the definition and the plugin's files, so each plugin update needs a new
review. This helper is that review for this plugin only: it asks `codex app-server` for the hooks (hooks/list),
prints the handoff ones, and with --yes records their current hashes (config/value/write). Same effect as approving
them under /hooks in the Codex TUI.

Usage: codex-trust.py [--yes] [--plugin handoff@claude-handoff] [--cwd DIR]
"""
import argparse, json, os, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument("--yes", action="store_true", help="record the trust (default: list only)")
ap.add_argument("--plugin", default="handoff@claude-handoff")
ap.add_argument("--cwd", default=os.path.expanduser("~"))
a = ap.parse_args()

p = subprocess.Popen(["codex", "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, text=True)
def call(i, method, params):
    p.stdin.write(json.dumps({"id": i, "method": method, "params": params}) + "\n"); p.stdin.flush()
    for line in p.stdout:
        m = json.loads(line)
        if m.get("id") == i:
            if "error" in m: sys.exit(f"{method} failed: {m['error']}")
            return m["result"]
    sys.exit(f"{method}: codex app-server exited")

try:
    call(1, "initialize", {"clientInfo": {"name": "handoff-trust", "version": "1"}})
    p.stdin.write(json.dumps({"method": "initialized"}) + "\n"); p.stdin.flush()
    res = call(2, "hooks/list", {"cwds": [a.cwd]})
    hooks = [h for d in res.get("data", []) for h in d.get("hooks", []) if h.get("pluginId") == a.plugin]
    if not hooks:
        sys.exit(f"no hooks of plugin {a.plugin} found (installed? `codex plugin list`)")
    todo = {}
    for h in hooks:
        print(f"{h['trustStatus']:>10}  {h['eventName']:<14} {h['command']}")
        if h["trustStatus"] != "trusted":
            todo[h["key"]] = {"trusted_hash": h["currentHash"]}
    if not todo:
        print("all trusted"); sys.exit(0)
    if not a.yes:
        print(f"{len(todo)} hook(s) not trusted; rerun with --yes to trust them"); sys.exit(1)
    call(3, "config/value/write", {"keyPath": "hooks.state", "mergeStrategy": "upsert", "value": todo})
    res = call(4, "hooks/list", {"cwds": [a.cwd]})
    bad = [h["key"] for d in res.get("data", []) for h in d.get("hooks", [])
           if h.get("pluginId") == a.plugin and h["trustStatus"] != "trusted"]
    if bad: sys.exit(f"still untrusted: {bad}")
    print(f"trusted {len(todo)} hook(s)")
finally:
    p.terminate()
