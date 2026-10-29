#!/usr/bin/env python3
"""Placement data contract and atomic capacity ledger (no launch authority).

Usage: fm-placement.py assess CONFIG DATA ID HARNESS MODEL EFFORT
       fm-placement.py memory
       fm-placement.py record STATE ID [spawn|recheck]
       fm-placement.py waits STATE
       fm-placement.py due STATE
memory reads fresh operating-system memory/swap evidence; assess consumes JSON
evidence on stdin and prints a complete decision.
record consumes that decision; one replace publishes the decision and its wait
in state/capacity.json, under an exclusive ledger lock. This is the capacity log.
waits prints P0-P3, oldest-first waits, with over_four_hours computed at read time.
due emits 'due' on a 900-second cadence or a changed resource fingerprint;
it never launches work. The watcher owns rechecks and normal wake delivery.
"""

import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid


def read(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


def atomic(path, value):
    fd, name = tempfile.mkstemp(prefix=".placement-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, separators=(",", ":"), allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def result(passed, reason):
    return {"status": "pass" if passed else "fail", "reason": reason}


def command(*args):
    return subprocess.check_output(args, text=True, timeout=10).strip()


def memory():
    if sys.platform == "darwin":
        pressure = command("memory_pressure", "-Q")
        free = re.search(r"free percentage:\s*(\d+)%", pressure)
        swap = re.search(r"used = ([\d.]+)([MG])", command("sysctl", "vm.swapusage"))
        if not free or not swap:
            raise ValueError("unreadable memory pressure or swap")
        return float(free[1]), float(swap[1]) * (1024 if swap[2] == "G" else 1)
    values = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        key, value = line.split(":", 1)
        values[key] = int(value.split()[0])
    return (100 * values["MemAvailable"] / values["MemTotal"],
            (values["SwapTotal"] - values["SwapFree"]) / 1024)


def assess(config, data, task, harness, model, effort):
    evidence = json.load(sys.stdin)
    checks = {name: result(False, "absent evidence") for name in ("fit", "room", "quota", "locks")}
    request = {"harness": harness, "model": model, "effort": effort}
    decision = {"task": task, "priority": "P2", "request": request, "checks": checks}
    for name in ("quota", "locks"):
        value = evidence.get(name)
        if isinstance(value, dict) and value.get("status") in ("pass", "fail"):
            checks[name] = value
    try:
        profile = read(config / "crew-placement.json")
        work = read(data / task / "placement.json")
        if not isinstance(profile, dict) or not isinstance(work, dict):
            raise ValueError("machine profile and task classification must be objects")
        if profile.get("version") != 1 or work.get("version") != 1:
            raise ValueError("placement version must be 1")
        if work.get("priority") not in ("P0", "P1", "P2", "P3"):
            raise ValueError("priority must be P0-P3")
        decision["priority"] = work["priority"]
        brief = data / task / "brief.md"
        if hashlib.sha256(brief.read_bytes()).hexdigest() != work.get("brief_sha256"):
            raise ValueError("task classification is not bound to current brief")
        workload = work.get("workload")
        allowed = profile.get("workloads")
        if not isinstance(allowed, list) or not allowed or not all(isinstance(x, str) for x in allowed):
            raise ValueError("machine workloads absent or invalid")
        if workload not in allowed:
            raise ValueError("workload is not allowed on this machine")
        needs_drive = work.get("requires_drive")
        if not isinstance(needs_drive, bool):
            raise ValueError("requires_drive must be explicit")
        if needs_drive and not profile.get("drive"):
            raise ValueError("work requires a drive this machine does not provide")
        dispatch = read(config / "crew-dispatch.json")
        if not isinstance(dispatch, dict):
            raise ValueError("dispatch configuration must be an object")
        rule = work.get("dispatch_rule")
        if not isinstance(rule, int) or isinstance(rule, bool) or rule < 0:
            raise ValueError("dispatch_rule must name a matched rule")
        selected = dispatch["rules"][rule]
        use = selected["use"]
        candidates = use if isinstance(use, list) else [use]
        if not candidates or not all(isinstance(c, dict) for c in candidates):
            raise ValueError("dispatch candidates absent or malformed")
        if sum(c.get("harness") == harness and c.get("model", "") == model
               and c.get("effort", "") == effort for c in candidates) != 1:
            raise ValueError("selected model is outside the task-fit dispatch rule")
        checks["fit"] = result(True, f"workload={workload}; dispatch_rule={rule}")
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        checks["fit"] = result(False, str(error))
        profile = None
    if profile is not None:
        try:
            cap = profile["max_crew"]
            floor = profile["min_free_memory_percent"]
            swap_cap = profile["max_swap_mib"]
            if type(cap) is not int or not 1 <= cap <= 4:
                raise ValueError("max_crew must be 1..4")
            if type(floor) not in (int, float) or not math.isfinite(floor) or not 0 < floor <= 100:
                raise ValueError("min_free_memory_percent must be >0..100")
            if type(swap_cap) not in (int, float) or not math.isfinite(swap_cap) or not 0 <= swap_cap < 1048576:
                raise ValueError("max_swap_mib invalid")
            count = evidence.get("crew_count")
            if type(count) is not int or count < 0 or count >= cap:
                raise ValueError(f"crew cap: count={count}, cap={cap}")
            free, swap = evidence.get("memory", {}).get("free_percent"), evidence.get("memory", {}).get("swap_mib")
            if not all(type(v) in (int, float) and math.isfinite(v) and v >= 0 for v in (free, swap)):
                raise ValueError("memory pressure or swap evidence absent")
            if free < floor or swap > swap_cap:
                raise ValueError(f"memory: free={free:g}%, swap={swap:g} MiB")
            disk = evidence.get("disk", {})
            if disk.get("status") != "pass":
                raise ValueError("disk floor absent or failed")
            drive = profile.get("drive")
            if drive is not None:
                path = Path(drive)
                if not path.is_absolute() or str(path.resolve()) != str(path) or not path.is_mount():
                    raise ValueError("required drive is not a real mount")
                # An actual create/unlink proves the selected account can write.
                fd, probe = tempfile.mkstemp(prefix=".fm-placement-", dir=path)
                os.close(fd)
                os.unlink(probe)
            slot = evidence.get("slots", {})
            if slot.get("status") not in ("pass", "not-installed"):
                raise ValueError("worktree room seam failed")
            checks["room"] = result(True, f"crew={count}/{cap}; free={free:g}%; swap={swap:g} MiB; slots={slot['status']}")
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            checks["room"] = result(False, str(error))
    decision["failed"] = [key for key, value in checks.items() if value["status"] != "pass"]
    decision["admitted"] = not decision["failed"]
    return decision


def ledger(state, operation, task=None, mode=None):
    state.mkdir(parents=True, exist_ok=True)
    with open(state / ".capacity-ledger.lock", "a", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = state / "capacity.json"
        value = read(path) if path.exists() else {"version": 1, "decisions": [], "waits": {}}
        now = int(time.time())
        if operation == "record":
            decision = json.load(sys.stdin)
            if decision.get("task") != task or mode not in ("spawn", "recheck"):
                raise ValueError("invalid decision identity")
            decision.update(at=now, id=uuid.uuid4().hex, mode=mode)
            value["decisions"].append(decision)
            old = value["waits"].get(task, {})
            if decision.get("hold"):
                value["waits"].pop(task, None)
            elif decision["admitted"] and mode == "spawn":
                value["waits"].pop(task, None)
            else:
                value["waits"][task] = {
                    "task": task, "since": now if old.get("state") == "hold" else old.get("since", now), "checked": now,
                    "priority": decision["priority"], "failed": decision["failed"],
                    "request": decision["request"],
                    "state": "ready" if decision["admitted"] else "capacity",
                }
            atomic(path, value)
            return decision
        if operation == "hold":
            if task in value["waits"]:
                value["waits"][task].update(state="hold", hold=mode)
                atomic(path, value)
            return True
        if operation == "waits":
            return sorted((dict(row, over_four_hours=row["state"] != "hold" and now - row["since"] > 14400)
                           for row in value["waits"].values()),
                          key=lambda row: (row["priority"], row["since"], row["task"]))
        if not value["waits"]:
            return False
        # Metadata removals cover teardown/auto-retire. Lock and explicit slot
        # reclaim signals cover room releases without creating another watcher.
        paths = list(state.glob("*.meta")) + list(state.glob(".spawn-*.lock"))
        paths += list(state.glob(".control-*.lock")) + list(state.glob(".treehouse-project-*.lock"))
        paths += [state / name for name in (".capacity-freed", ".task-set.lock",
                                            ".claude-admission.lock", ".quota-pacing-admission.lock")]
        fingerprint = hashlib.sha256(repr(sorted(
            (str(p), p.stat().st_mtime_ns) for p in paths if p.exists()
        )).encode()).hexdigest()
        due = value.get("last_recheck", 0) + 900 <= now or value.get("fingerprint") != fingerprint
        if due:
            value.update(last_recheck=now, fingerprint=fingerprint)
            atomic(path, value)
        return due


def main():
    operation, *args = sys.argv[1:]
    if operation == "memory":
        free, swap = memory()
        output = {"free_percent": free, "swap_mib": swap}
    elif operation == "assess":
        config, data, task, harness, model, effort = args
        output = assess(Path(config), Path(data), task, harness, model, effort)
    else:
        state, *rest = args
        output = ledger(Path(state), operation, *rest)
    if operation == "due":
        if output:
            print("due")
    else:
        print(json.dumps(output, separators=(",", ":"), allow_nan=False))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as failure:
        print(f"placement: {failure}", file=sys.stderr)
        sys.exit(1)
