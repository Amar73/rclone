#!/usr/bin/env python3
"""Читает разметка '---HOST:x---'/JSON/'---END:x---' из stdin,
сливает с state_file (сохраняя историю и stale-статус), пишет out_file."""
import json
import sys

state_file, out_file = sys.argv[1], sys.argv[2]

lines = sys.stdin.read().splitlines()
now = lines[0] if lines else None

with open(state_file) as f:
    state = json.load(f)

i = 1
current_host = None
buf = []
while i < len(lines):
    line = lines[i]
    if line.startswith("---HOST:") and line.endswith("---"):
        current_host = line[len("---HOST:"):-len("---")]
        buf = []
    elif line.startswith("---END:") and line.endswith("---"):
        raw = "\n".join(buf).strip()
        prev = state.get(current_host, {})

        # A payload is only accepted as a real backup_status.sh status if it
        # parses to a dict, carries the "host" key that backup_status.sh
        # always includes in its final JSON assembly, and does not carry an
        # "error" key (the shape emitted by backup_status.sh --print when the
        # remote status file is missing, e.g. {"error":"status file not
        # found"}). Anything else -- JSON parse failure, non-dict JSON, or
        # this error shape -- is treated identically: preserve whatever
        # previous state we have and mark the host stale, rather than
        # silently overwriting last-known-good data.
        data = None
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, dict) and "host" in parsed and "error" not in parsed:
                data = parsed
        except (json.JSONDecodeError, TypeError):
            data = None

        if data is not None:
            data["stale"] = False
            data["last_seen"] = now

            history = prev.get("history", [])
            new_success = data.get("last_success")
            prev_success = prev.get("last_success")
            if new_success and (
                not prev_success
                or new_success.get("finished_at") != prev_success.get("finished_at")
            ):
                history.append({
                    "finished_at": new_success.get("finished_at"),
                    "result": new_success.get("result"),
                    "errors": new_success.get("errors"),
                })
                history = history[-14:]
            data["history"] = history

            state[current_host] = data
        else:
            if current_host in state:
                state[current_host]["stale"] = True
            else:
                state[current_host] = {
                    "host": current_host, "stale": True,
                    "last_seen": None, "history": [],
                }
        current_host = None
    elif current_host is not None:
        buf.append(line)
    i += 1

with open(state_file, "w") as f:
    json.dump(state, f, indent=2)

with open(out_file, "w") as f:
    json.dump({"generated_at": now, "hosts": state}, f, indent=2)
