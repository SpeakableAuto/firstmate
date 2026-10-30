#!/usr/bin/env python3
"""Daily internal-volume growth check behind bin/fm-internal-growth.sh.

That script's header owns configuration, state, alert, and log semantics.
Usage: fm-internal-growth.py <config> <state-dir> <wake-script> [--dry-run]
"""
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

GIB = 1024 * 1024  # KiB per GiB


def fail_config(message):
    print(f"invalid internal-growth configuration: {message}", file=sys.stderr)
    sys.exit(2)


def plain_abs(path):
    return (path.startswith("/") and "\n" not in path and
            os.path.normpath(path) == path and path != "/")


def read_config(path):
    if not os.path.isfile(path) or os.path.islink(path):
        print(f"internal growth check not configured: {path}", file=sys.stderr)
        sys.exit(2)
    cfg = {"volume": None, "threshold_gib": 1, "depth": 3, "min_baseline_hours": 20,
           "timeout_seconds": 1800, "scan": [], "allow": []}
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            key, sep, value = line.partition("=")
            if not sep:
                fail_config(line)
            if key == "volume":
                cfg["volume"] = value
            elif key in ("threshold_gib", "depth", "min_baseline_hours", "timeout_seconds"):
                zero_ok = key == "min_baseline_hours" and value == "0"
                if not value.isdigit() or (value.startswith("0") and not zero_ok) or int(value) > 1048576:
                    fail_config(line)
                cfg[key] = int(value)
            elif key in ("scan", "allow"):
                cfg[key].append(value)
            else:
                fail_config(line)
    if not cfg["volume"] or not plain_abs(cfg["volume"]) and cfg["volume"] != "/":
        fail_config("volume must be an absolute path")
    if not cfg["scan"]:
        fail_config("at least one scan= path is required")
    for path in cfg["scan"] + cfg["allow"]:
        if not plain_abs(path):
            fail_config(f"not a plain absolute path: {path}")
    for a in cfg["scan"]:
        for b in cfg["scan"]:
            if a != b and under(b, a):
                fail_config(f"scan paths overlap: {a} contains {b}")
    return cfg


def under(path, parent):
    return path == parent or path.startswith(parent.rstrip("/") + "/")


class Budget:
    """One wall-clock allowance for every measurement operation in a run."""

    def __init__(self, seconds):
        self.seconds = seconds
        self.deadline = time.monotonic() + seconds

    def remaining(self, path):
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise RuntimeError(f"measurement exceeded {self.seconds} seconds at {path}")
        return left


def volume_usage(volume, budget):
    try:
        proc = subprocess.run(["df", "-kP", volume], capture_output=True, text=True,
                              check=False, timeout=budget.remaining(volume))
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"df exceeded the {budget.seconds} second budget at {volume}") from error
    lines = [line for line in proc.stdout.splitlines() if line.strip()]
    fields = lines[-1].split() if len(lines) >= 2 else []
    if proc.returncode or len(fields) < 6 or not all(value.isdigit() for value in fields[1:4]):
        raise RuntimeError(f"df could not measure {volume}")
    return int(fields[2]), int(fields[3])


def unreadable_paths(stderr):
    paths = set()
    for line in stderr.splitlines():
        if not line.startswith("du: ") or ": " not in line[4:]:
            continue
        candidate = line[4:].rsplit(": ", 1)[0]
        for prefix in ("cannot read directory ", "cannot access "):
            if candidate.startswith(prefix):
                candidate = candidate[len(prefix):]
        candidate = candidate.strip("'`\"")
        if candidate.startswith("/"):
            paths.add(candidate.rstrip("/") or "/")
    return paths


def du(args, budget):
    try:
        proc = subprocess.run(["du", "-xk"] + args, capture_output=True, text=True,
                              check=False, timeout=budget.remaining(args[-1]))
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"du exceeded the {budget.seconds} second budget at {args[-1]}") from error
    sizes = {}
    for line in proc.stdout.splitlines():
        size, sep, path = line.partition("\t")
        if sep and size.isdigit():
            sizes[path.rstrip("/") or "/"] = int(size)
    return sizes, unreadable_paths(proc.stderr)


def measure(cfg, budget, unmeasured):
    """Folder sizes in KiB on the internal volume, keyed by path."""
    device = os.stat(cfg["volume"]).st_dev
    sizes = {}
    for scan in cfg["scan"]:
        if not os.path.isdir(scan) or os.path.islink(scan):
            raise RuntimeError(f"scan path missing or symlinked: {scan}")
        if os.stat(scan).st_dev != device:
            raise RuntimeError(f"scan path is not on {cfg['volume']}: {scan}")
        found, inaccessible = du(["-d", str(cfg["depth"]), scan], budget)
        unmeasured.update(inaccessible)
        if scan not in found:
            raise RuntimeError(f"du produced no total for {scan}")
        sizes.update(found)
    direct = []
    for path in cfg["allow"]:
        if path in sizes or not os.path.lexists(path):
            continue
        if not os.path.isdir(path) or os.path.islink(path):
            raise RuntimeError(f"allowed path is not a real directory: {path}")
        if os.stat(path).st_dev != device:
            raise RuntimeError(f"allowed path is not on {cfg['volume']}: {path}")
        direct.append(path)
    if direct:
        found, inaccessible = du(["-s"] + direct, budget)
        sizes.update(found)
        unmeasured.update(inaccessible)
        unmeasured.update(path for path in direct if path not in found)
    return sizes


def allowed(path, allow):
    return any(under(path, a) for a in allow)


def flagged_paths(base, cur, allow, threshold_kib):
    growth = {p: cur.get(p, 0) - base.get(p, 0) for p in set(base) | set(cur)}
    outer_allowed = [a for a in growth if allowed(a, allow)
                     and not any(a != b and under(a, b) for b in growth if allowed(b, allow))]
    over = {}
    for path, grew in growth.items():
        if allowed(path, allow):
            continue
        excluded = sum(growth[a] for a in outer_allowed if a != path and under(a, path))
        if grew - excluded > threshold_kib:
            over[path] = grew - excluded
    deepest = [p for p in over if not any(q != p and under(q, p) for q in over)]
    flagged = sorted(({"kind": "folder", "path": p, "growth_kib": over[p],
                       "before_kib": base.get(p, 0), "after_kib": cur.get(p, 0)}
                      for p in deepest), key=lambda row: -row["growth_kib"])
    return flagged, sum(growth[path] for path in outer_allowed)


def read_tsv(path):
    rows = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("#"):
                    continue
                key, _, value = line.rstrip("\n").partition("\t")
                rows[value] = key
    return rows


def read_baseline(path):
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as handle:
        header = json.loads(handle.readline().lstrip("# "))
    return header, {p: int(s) for p, s in read_tsv(path).items()}


def atomic_write(path, text):
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=os.path.dirname(path))
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(tmp, path)


def gib(kib):
    return f"{kib / GIB:.1f} GiB"


def episode_key(row):
    if row.get("kind") == "unmeasured":
        return f"!unmeasured:{row['path']}"
    if row.get("kind") == "unexplained-volume":
        return "!unexplained-volume"
    return row["path"]


def alert_text(rows, unmeasured):
    details = []
    for row in rows:
        if row.get("kind") == "unmeasured":
            continue
        if row.get("kind") == "unexplained-volume":
            details.append(f"unexplained volume growth (+{gib(row['growth_kib'])})")
        else:
            details.append(f"{row['path']} (+{gib(row['growth_kib'])})")
    if unmeasured:
        details.append("UNMEASURED: " + ", ".join(unmeasured))
    return "; ".join(details)


def main():
    if len(sys.argv) not in (4, 5) or (len(sys.argv) == 5 and sys.argv[4] != "--dry-run"):
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    cfg_path, state_dir, wake = sys.argv[1:4]
    dry = len(sys.argv) == 5
    cfg = read_config(cfg_path)
    now = int(time.time())
    baseline_path = os.path.join(state_dir, "baseline.tsv")
    episodes_path = os.path.join(state_dir, "episodes.tsv")
    log_path = os.path.join(state_dir, "log.jsonl")
    if not dry:
        os.makedirs(state_dir, mode=0o700, exist_ok=True)
    episodes = read_tsv(episodes_path)  # path -> opened epoch
    record = {"at": now, "volume": cfg["volume"], "threshold_gib": cfg["threshold_gib"]}
    alert = None
    def expired(_signum, _frame):
        raise TimeoutError(f"measurement exceeded {cfg['timeout_seconds']} seconds")

    unmeasured = set()
    budget = Budget(cfg["timeout_seconds"])
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, budget.remaining(cfg["volume"]))
    try:
        record["used_kib"], record["free_kib"] = volume_usage(cfg["volume"], budget)
        cur = measure(cfg, budget, unmeasured)
    except (OSError, RuntimeError) as error:
        record["error"] = str(error)
        flagged = [{"kind": "measurement", "path": "!measurement", "growth_kib": 0}]
        if "!measurement" not in episodes:
            alert = f"internal growth check could not measure: {error}"
        cur = None
    signal.setitimer(signal.ITIMER_REAL, 0)
    record["unmeasured"] = sorted(unmeasured)
    if alert and unmeasured:
        alert += "; UNMEASURED: " + ", ".join(sorted(unmeasured))
    if cur is not None:
        loaded = read_baseline(baseline_path)
        if loaded is None:
            record["baseline"] = "created"
            growth_flagged = []
        else:
            header, base = loaded
            record["baseline_at"] = header["at"]
            record["used_delta_kib"] = record["used_kib"] - header["used_kib"]
            growth_flagged, allowed_growth = flagged_paths(
                base, cur, cfg["allow"], cfg["threshold_gib"] * GIB)
            record["allowed_growth_kib"] = allowed_growth
            explained = sum(row["growth_kib"] for row in growth_flagged)
            record["unexplained_growth_kib"] = record["used_delta_kib"] - allowed_growth - explained
            if record["unexplained_growth_kib"] > cfg["threshold_gib"] * GIB:
                growth_flagged.append({"kind": "unexplained-volume", "path": cfg["volume"],
                                       "growth_kib": record["unexplained_growth_kib"]})
        flagged = growth_flagged + [
            {"kind": "unmeasured", "path": path, "growth_kib": 0}
            for path in sorted(unmeasured)
        ]
        new = [row for row in flagged if episode_key(row) not in episodes]
        if new:
            since = (time.strftime('%Y-%m-%dT%H:%MZ', time.gmtime(loaded[0]["at"]))
                     if loaded is not None else "the first measurement")
            alert = (f"internal growth issue since {since}: {alert_text(new, sorted(unmeasured))}; "
                     f"{cfg['volume']} free {gib(record['free_kib'])}; log {log_path}")
    record["flagged"] = flagged
    record["new"] = [episode_key(row) for row in flagged if episode_key(row) not in episodes]
    if dry:
        print(json.dumps(dict(record, alert=alert), sort_keys=True))
        return 0 if cur is not None else 1
    alerted = True
    if alert:
        alerted = subprocess.run(["bash", wake, "--queue-alert", alert], check=False).returncode == 0
        record["alert"] = alert if alerted else None
        if not alerted:
            print("could not queue the internal-growth alert; it is retried next run", file=sys.stderr)
    # One alert per episode: an open episode stays silent until a run clears it.
    still = {episode_key(row): episodes.get(episode_key(row), str(now)) for row in flagged
             if alerted or episode_key(row) in episodes}
    if cur is None:
        # A failed measurement says nothing about folders already alerted on.
        still = dict(episodes, **still)
    atomic_write(episodes_path, "".join(f"{since}\t{path}\n" for path, since in sorted(still.items())))
    if cur is not None:
        loaded = read_baseline(baseline_path)
        if loaded is None or now - loaded[0]["at"] >= cfg["min_baseline_hours"] * 3600:
            header = json.dumps({"at": now, "used_kib": record["used_kib"],
                                 "free_kib": record["free_kib"]})
            atomic_write(baseline_path, f"# {header}\n" +
                         "".join(f"{size}\t{path}\n" for path, size in sorted(cur.items())))
            record["baseline_rolled"] = True
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")
    return 0 if alerted and cur is not None else 1


if __name__ == "__main__":
    sys.exit(main())
