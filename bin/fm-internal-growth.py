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
           "timeout_seconds": 1800, "scan": [], "allow": [], "exclude": []}
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
            elif key in ("scan", "allow", "exclude"):
                cfg[key].append(value)
            else:
                fail_config(line)
    if not cfg["volume"] or not plain_abs(cfg["volume"]) and cfg["volume"] != "/":
        fail_config("volume must be an absolute path")
    if not cfg["scan"]:
        fail_config("at least one scan= path is required")
    for path in cfg["scan"] + cfg["allow"] + cfg["exclude"]:
        if not plain_abs(path):
            fail_config(f"not a plain absolute path: {path}")
    for a in cfg["scan"]:
        for b in cfg["scan"]:
            if a != b and under(b, a):
                fail_config(f"scan paths overlap: {a} contains {b}")
    return cfg


def under(path, parent):
    return path == parent or path.startswith(parent.rstrip("/") + "/")


def free_kib(volume):
    stat = os.statvfs(volume)
    return stat.f_bavail * stat.f_frsize // 1024


class Budget:
    """One wall-clock allowance for every du call in a run."""

    def __init__(self, seconds):
        self.seconds = seconds
        self.deadline = time.monotonic() + seconds

    def remaining(self, path):
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise RuntimeError(f"measurement exceeded {self.seconds} seconds at {path}")
        return left


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
    return sizes


def measure_tree(path, depth, device, cfg, budget, sizes, unreadable):
    """Measure path; record it and its descendants down to depth; return KiB.

    A subtree holding an excluded folder is split by listing its entries, so
    the excluded folder itself is never opened.
    """
    if not any(e != path and under(e, path) for e in cfg["exclude"]):
        found = du(["-d", str(max(depth, 0)), path] if depth >= 0 else ["-s", path], budget)
        if path not in found:
            if path in cfg["scan"]:
                raise RuntimeError(f"du produced no total for {path}")
            # An unreadable folder inside a split scan counts as empty and is logged.
            unreadable.append(path)
            return 0
        if depth >= 0:
            sizes.update(found)
        return found[path]
    total = os.lstat(path).st_blocks * 512 // 1024
    with os.scandir(path) as entries:
        for entry in entries:
            child = os.path.join(path, entry.name)
            if child in cfg["exclude"]:
                continue
            stat = entry.stat(follow_symlinks=False)
            if stat.st_dev != device:
                continue
            if entry.is_dir(follow_symlinks=False):
                total += measure_tree(child, depth - 1, device, cfg, budget, sizes, unreadable)
            else:
                total += stat.st_blocks * 512 // 1024
    if depth >= 0:
        sizes[path] = total
    return total


def measure(cfg, unreadable):
    """Folder sizes in KiB on the internal volume, keyed by path."""
    device = os.stat(cfg["volume"]).st_dev
    budget = Budget(cfg["timeout_seconds"])
    sizes = {}
    for scan in cfg["scan"]:
        if not os.path.isdir(scan) or os.path.islink(scan):
            raise RuntimeError(f"scan path missing or symlinked: {scan}")
        if os.stat(scan).st_dev != device:
            raise RuntimeError(f"scan path is not on {cfg['volume']}: {scan}")
        if scan in cfg["exclude"]:
            continue
        measure_tree(scan, cfg["depth"], device, cfg, budget, sizes, unreadable)
        # Allowed folders deeper than the scan depth are measured directly so
        # their growth can still be excluded from every ancestor.
        deep = [a for a in cfg["allow"] if under(a, scan) and a not in sizes and os.path.isdir(a)
                and not any(under(a, e) for e in cfg["exclude"])]
        if deep:
            sizes.update(du(["-s"] + deep, budget))
    return sizes


def allowed(path, allow):
    return any(under(path, a) for a in allow)


def flagged_paths(base, cur, allow, threshold_kib):
    growth = {p: cur[p] - base.get(p, 0) for p in cur}
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
    return sorted(({"path": p, "growth_kib": over[p], "before_kib": base.get(p, 0),
                    "after_kib": cur[p]} for p in deepest), key=lambda row: -row["growth_kib"])


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

    # Backstop for a filesystem call that blocks outside du's own timeout.
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(cfg["timeout_seconds"] + 60)
    try:
        record["free_kib"] = free_kib(cfg["volume"])
        record["unreadable"] = []
        cur = measure(cfg, record["unreadable"])
    except (OSError, RuntimeError) as error:
        record["error"] = str(error)
        flagged = [{"path": "!measurement", "growth_kib": 0}]
        if "!measurement" not in episodes:
            alert = f"internal growth check could not measure: {error}"
        cur = None
    signal.alarm(0)
    if cur is not None:
        loaded = read_baseline(baseline_path)
        if loaded is None:
            record["baseline"] = "created"
            flagged = []
        else:
            header, base = loaded
            record["baseline_at"] = header["at"]
            record["used_delta_kib"] = header["free_kib"] - record["free_kib"]
            flagged = flagged_paths(base, cur, cfg["allow"], cfg["threshold_gib"] * GIB)
            new = [row for row in flagged if row["path"] not in episodes]
            if new:
                listed = ", ".join(f"{row['path']} (+{gib(row['growth_kib'])})" for row in new)
                alert = (f"internal growth over {cfg['threshold_gib']} GiB outside the allowed list since "
                         f"{time.strftime('%Y-%m-%dT%H:%MZ', time.gmtime(header['at']))}: {listed}; "
                         f"{cfg['volume']} free {gib(record['free_kib'])}; log {log_path}")
    record["flagged"] = flagged
    record["new"] = [row["path"] for row in flagged if row["path"] not in episodes]
    if dry:
        print(json.dumps(dict(record, alert=alert), sort_keys=True))
        return 0
    alerted = True
    if alert:
        alerted = subprocess.run(["bash", wake, "--queue-alert", alert], check=False).returncode == 0
        record["alert"] = alert if alerted else None
        if not alerted:
            print("could not queue the internal-growth alert; it is retried next run", file=sys.stderr)
    # One alert per episode: an open episode stays silent until a run clears it.
    still = {row["path"]: episodes.get(row["path"], str(now)) for row in flagged
             if alerted or row["path"] in episodes}
    if cur is None:
        # A failed measurement says nothing about folders already alerted on.
        still = dict(episodes, **still)
    atomic_write(episodes_path, "".join(f"{since}\t{path}\n" for path, since in sorted(still.items())))
    if cur is not None:
        loaded = read_baseline(baseline_path)
        if loaded is None or now - loaded[0]["at"] >= cfg["min_baseline_hours"] * 3600:
            header = json.dumps({"at": now, "free_kib": record["free_kib"]})
            atomic_write(baseline_path, f"# {header}\n" +
                         "".join(f"{size}\t{path}\n" for path, size in sorted(cur.items())))
            record["baseline_rolled"] = True
    with open(log_path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")
    return 0 if alerted and cur is not None else 1


if __name__ == "__main__":
    sys.exit(main())
