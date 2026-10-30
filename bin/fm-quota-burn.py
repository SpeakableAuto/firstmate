#!/usr/bin/env python3
"""Measured quota draw per model, from this home's own samples (read-only to quota).

Usage: fm-quota-burn.py sample STATE SNAPSHOT CREWS NOW
       fm-quota-burn.py rates STATE NOW

sample appends one record to STATE/quota-samples.jsonl: for every provider row
in the quota-axi --json SNAPSHOT, its all_models effective percentage, limiting
window, and that window's reset; plus CREWS, a JSON array of this home's live
crew as {task, provider, model}. A sample less than 60 seconds after the last
one is skipped, and records older than 8 days are pruned, under an exclusive
lock on STATE/.quota-samples.lock.

rates prints one JSON object measured from those samples:
  {"models": {"<provider>:<model>": M}, "providers": {"<provider>": M}}
  M = {points_per_hour, crew_hours, run_seconds, draw, span}
Between two consecutive samples of one account (at most 3 hours apart, same
limiting window and reset, no refill) the percentage the account lost is split
equally across the crew live at the first sample, giving points per crew-hour
by model. run_seconds is the median lifetime of finished crew (first to last
sample seen). draw is the points one new crew is expected to take
(points_per_hour x run_seconds, clamped 0.5..40) and span is the seconds over
which that draw is still owed (run_seconds clamped 900..14400). A model or
provider with under half a crew-hour of evidence is omitted, so the caller
keeps its fixed default. Supervisor and other non-crew use on an account is
attributed to its crew, which overstates rather than hides draw.
docs/configuration.md "Quota balance" owns how the resolver applies them.
"""

import fcntl
import json
import os
from pathlib import Path
import statistics
import sys
import tempfile

KEEP_SECONDS = 8 * 86400
MIN_GAP = 60
MAX_PAIR = 3 * 3600
MIN_HOURS = 0.5


def bare(model):
    model = model or "default"
    return model.split("/")[-1] or "default"


def rows_of(snapshot):
    rows = []
    for provider in snapshot.get("providers") or []:
        if not isinstance(provider, dict) or provider.get("notSetUp"):
            continue
        windows = {w.get("id"): w for w in provider.get("windows") or [] if isinstance(w, dict)}
        for scope in (provider.get("quotaSemantics") or {}).get("effectiveAvailability") or []:
            if scope.get("scope") not in ("all_models", "all_products") or scope.get("status") != "known":
                continue
            pct = scope.get("effectivePercentRemaining")
            if type(pct) not in (int, float):
                continue
            limiting = ((scope.get("limitingWindowIds") or [None])[0]
                        or (scope.get("runway") or {}).get("limitingWindowId"))
            rows.append({"provider": provider.get("provider"), "account": provider.get("accountKey") or "",
                         "pct": pct, "limiting": limiting,
                         "resets": (windows.get(limiting) or {}).get("resetsAt")})
            break
    return rows


def load(path, now):
    samples = []
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if isinstance(record, dict) and type(record.get("at")) is int and now - record["at"] <= KEEP_SECONDS:
                samples.append(record)
    return sorted(samples, key=lambda record: record["at"])


def sample(state, snapshot_path, crews_path, now):
    state.mkdir(parents=True, exist_ok=True)
    snapshot = json.loads(Path(snapshot_path).read_text(encoding="utf-8"))
    crews = json.loads(Path(crews_path).read_text(encoding="utf-8"))
    if not isinstance(crews, list):
        raise ValueError("crews must be a JSON array")
    record = {"at": now, "rows": rows_of(snapshot),
              "crews": [{"task": str(c.get("task")), "provider": str(c.get("provider")), "model": bare(c.get("model"))}
                        for c in crews if isinstance(c, dict)]}
    path = state / "quota-samples.jsonl"
    with open(state / ".quota-samples.lock", "a", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        samples = load(path, now)
        if samples and now - samples[-1]["at"] < MIN_GAP:
            return
        samples.append(record)
        fd, name = tempfile.mkstemp(prefix=".quota-samples-", dir=state)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                for item in samples:
                    stream.write(json.dumps(item, separators=(",", ":")) + "\n")
            os.replace(name, path)
        finally:
            if os.path.exists(name):
                os.unlink(name)


def measured(points, hours, lifetimes, fallback_run):
    if hours < MIN_HOURS:
        return None
    rate = points / hours
    run = statistics.median(lifetimes) if lifetimes else fallback_run
    return {"points_per_hour": round(rate, 4), "crew_hours": round(hours, 3), "run_seconds": int(run),
            "draw": round(min(40.0, max(0.5, rate * run / 3600)), 3), "span": int(min(14400, max(900, run)))}


def rates(state, now):
    samples = load(state / "quota-samples.jsonl", now)
    points, hours = {}, {}
    series = {}
    for record in samples:
        for row in record.get("rows") or []:
            series.setdefault((row.get("provider"), row.get("account")), []).append((record, row))
    for (provider, _account), items in series.items():
        for (first, a), (second, b) in zip(items, items[1:]):
            gap = second["at"] - first["at"]
            if not 0 < gap <= MAX_PAIR or a.get("limiting") != b.get("limiting") or a.get("resets") != b.get("resets"):
                continue
            lost = a["pct"] - b["pct"]
            crews = [c for c in first.get("crews") or [] if c.get("provider") == provider]
            if lost < 0 or not crews:
                continue
            share = lost / len(crews)
            for crew in crews:
                for key in (f'{provider}:{crew["model"]}', provider):
                    points[key] = points.get(key, 0.0) + share
                    hours[key] = hours.get(key, 0.0) + gap / 3600
    seen = {}
    for record in samples:
        for crew in record.get("crews") or []:
            first_at, _last, key = seen.get(crew["task"], (record["at"], record["at"], f'{crew["provider"]}:{crew["model"]}'))
            seen[crew["task"]] = (first_at, record["at"], key)
    latest = samples[-1]["at"] if samples else now
    lifetimes = {}
    for first_at, last_at, key in seen.values():
        if last_at < latest and last_at > first_at:
            for name in (key, key.split(":")[0]):
                lifetimes.setdefault(name, []).append(last_at - first_at)
    output = {"models": {}, "providers": {}}
    for key in points:
        provider = key.split(":")[0]
        fallback = statistics.median(lifetimes[provider]) if lifetimes.get(provider) else 3600
        value = measured(points[key], hours[key], lifetimes.get(key, []), fallback)
        if value is not None:
            output["providers" if ":" not in key else "models"][key] = value
    return output


def main():
    operation, *args = sys.argv[1:]
    if operation == "sample" and len(args) == 4:
        sample(Path(args[0]), args[1], args[2], int(args[3]))
    elif operation == "rates" and len(args) == 2:
        print(json.dumps(rates(Path(args[0]), int(args[1])), separators=(",", ":"), sort_keys=True))
    else:
        raise ValueError("usage: sample STATE SNAPSHOT CREWS NOW | rates STATE NOW")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"quota-burn: {error}", file=sys.stderr)
        sys.exit(1)
