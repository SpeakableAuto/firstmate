#!/usr/bin/env python3
"""Replay a recorded week of crew starts through the quota balance selection.

Usage: fm-quota-balance-replay.py ROOT HOME REMOTE_HOME FIXTURE MODE
MODE historical keeps each start on the provider it really used; balanced asks
the real bin/fm-dispatch-resolve.sh --rule ... --check for the pick at every
start, against quota snapshots simulated from the fixture's measured draw, for
this machine (HOME) and the second machine (REMOTE_HOME, reached through the
caller's fake ssh as second mate m0002, which shares the Codex account).
A start the resolver holds is retried 15 minutes later. Prints one JSON summary;
REPLAY_TRACE=1 also prints every placement and the allowances on stderr.
Both homes hold config/crew-dispatch.json; PATH must serve a quota-axi that
prints the file named by QUOTA_FIXTURE, which the fake ssh points at
REMOTE_QUOTA_FIXTURE for the remote read.
"""

import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import time

# Each machine's allowances: Claude is per machine, Codex is one shared account.
ALLOWANCE = {("local", "claude"): "claude", ("local", "codex"): "codex",
             ("m0002", "claude"): "claude_m0002", ("m0002", "codex"): "codex"}
RULE_OF = {"trivial": "rule_1", "design": "rule_2", "hard": "rule_3", "default": "default"}
PROFILE_OF = {"codex:gpt-6-astra": ("codex", "gpt-6-astra", "high"), "codex:gpt-6-luna": ("codex", "gpt-6-luna", "high"),
              "codex:gpt-6-sol": ("codex", "gpt-6-sol", "high"), "claude:opus": ("claude", "opus", "high"),
              "claude:fable": ("claude", "fable", "high"), "claude:default": ("claude", "opus", "high")}


def epoch(text):
    return int(datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp())


class Sim:
    def __init__(self, fixture):
        self.start = epoch(fixture["start"])
        self.now = self.start
        self.pct = {name: float(a["percent"]) for name, a in fixture["allowances"].items()}
        self.resets = {name: [epoch(r) for r in a["resets"]] for name, a in fixture["allowances"].items()}
        self.window = {name: a["window_hours"] * 3600 for name, a in fixture["allowances"].items()}
        self.draw = fixture["draw"]
        self.crews = []

    def next_reset(self, name):
        return min(r for r in self.resets[name] if r > self.now)

    def headroom(self, name, charged=False):
        left = 100 * (self.next_reset(name) - self.now) / self.window[name]
        owed = sum(c["rate"] * (c["end"] - self.now) for c in self.crews if c["provider"] == name) if charged else 0
        return round(self.pct[name] - owed - left, 2)

    def advance(self, until):
        while self.now < until:
            step = min(until, self.now + 300)
            for name in self.pct:
                due = [r for r in self.resets[name] if self.now < r <= step]
                lost = 0.0
                for crew in self.crews:
                    if crew["provider"] == name:
                        overlap = max(0, min(step, crew["end"]) - max(self.now, crew["start"]))
                        lost += crew["rate"] * overlap
                lost += self.draw[name].get("background_points_per_hour", 0) * (step - self.now) / 3600
                self.pct[name] = max(0.0, self.pct[name] - lost)
                if due:
                    self.pct[name] = 100.0
            self.now = step
            self.crews = [c for c in self.crews if c["end"] > self.now]

    def place(self, provider, home="local"):
        run = self.draw[provider]["run_seconds"]
        self.crews.append({"provider": provider, "home": home, "start": self.now, "end": self.now + run,
                           "rate": self.draw[provider]["points_per_start"] / run})

    def snapshot(self, claude="claude"):
        def row(name, extra_windows, provider=None):
            scope = {"status": "known", "effectivePercentRemaining": round(self.pct[name], 2),
                     "pace": {"worstReservePercentPoints": self.headroom(name)},
                     "runway": {"status": "projected_exhaustion"}, "selection": {"spendPriority": 0}}
            scopes = [dict(scope, scope="all_models")]
            if name.startswith("claude"):
                scopes.append(dict(scope, scope="model:fable"))
            return {"provider": provider or name, "state": {"status": "fresh", "stale": False}, "windows": extra_windows,
                    "quotaSemantics": {"status": "known", "effectiveAvailability": scopes}}
        return {"schemaVersion": 5, "providers": [
            row(claude, [{"id": "five_hour", "kind": "session", "percentRemaining": 80}], "claude"),
            row("codex", [{"id": "weekly", "kind": "weekly", "percentRemaining": round(self.pct["codex"], 2),
                           "resetsAt": self.iso(self.next_reset("codex"))}])]}

    def iso(self, at):
        return datetime.datetime.fromtimestamp(at, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")

    def signature(self, name):
        # The account signature the resolver derives from the windows' resets:
        # only Codex windows carry one here, as the shared account does live.
        return f"codex|weekly@{self.iso(self.next_reset('codex'))}" if name == "codex" else None


def ask(root, home, remote, sim, start, brief):
    # Live Claude crew are counted as recent launches, so each machine's real
    # seat cap applies; every in-flight crew is still owed as a measured charge,
    # exactly as the real ledger holds it: its draw decays over its run from its
    # wall-clock start, under the same key as its crew record.
    wall = int(time.time())
    entries = []
    for where, home_id, claude in ((home, "local", "claude"), (remote, "m0002", "claude_m0002")):
        state = where / "state"
        for stale in list(state.glob("crew*.meta")) + [state / "quota-samples.jsonl"]:
            stale.unlink(missing_ok=True)
        claude_n = 0
        for i, crew in enumerate(c for c in sim.crews if c["home"] == home_id):
            provider = "codex" if crew["provider"] == "codex" else "claude"
            key = f"codex-{home_id}-{i}"
            if provider == "claude":
                claude_n += 1
                key = f"crew{claude_n}"
                (state / f"{key}.meta").write_text(
                    f"harness=claude\nkind=ship\nbackend=unknown\nwindow=recorded-{claude_n}\naccount=ordinary\nspawn_gen=s{wall}.1.1\n")
            entries.append({"at": wall - (sim.now - crew["start"]), "key": key, "home": home_id, "provider": provider,
                            "account": "", "model": "", "claude": provider == "claude",
                            "scopes": ["all_models"] + (["model:fable"] if provider == "claude" else []),
                            "signature": sim.signature(crew["provider"]),
                            "draw": crew["rate"] * (crew["end"] - crew["start"]), "span": crew["end"] - crew["start"]})
    with open(home / "state" / "dispatch-charges.jsonl", "w") as ledger:
        for entry in entries:
            if entry["signature"] is None:
                del entry["signature"]
            ledger.write(json.dumps(entry) + "\n")
    for cached in (home / "state" / "quota-remote").glob("*"):
        cached.unlink()
    Path(os.environ["QUOTA_FIXTURE"]).write_text(json.dumps(sim.snapshot()))
    Path(os.environ["REMOTE_QUOTA_FIXTURE"]).write_text(json.dumps(sim.snapshot("claude_m0002")))
    harness, model, effort = PROFILE_OF[start["historical"]]
    if start["class"] == "design":
        harness, model, effort = "claude", "fable", "high"
    env = dict(os.environ, FM_HOME=str(home))
    env.pop("TYPESAFE_API_KEY", None)
    env.pop("CLAUDE_CONFIG_DIR", None)
    out = subprocess.run([str(root / "bin/fm-dispatch-resolve.sh"), "--rule", RULE_OF[start["class"]],
                          "--check", harness, model, effort, str(brief), "--project", "app"],
                         env=env, capture_output=True, text=True, check=True).stdout.strip().splitlines()[-1]
    result = json.loads(out)
    return result, result["check"]["verdict"]


def main():
    root, home, remote, fixture_path, mode = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], sys.argv[5]
    fixture = json.loads(Path(fixture_path).read_text())
    sim = Sim(fixture)
    brief = home / "brief.md"
    brief.write_text("# Task\nReplayed crew start.\n")
    queue = sorted(({**s, "due": sim.start + s["offset"]} for s in fixture["starts"]), key=lambda s: s["due"])
    end = epoch(fixture["end"])
    placed = {name: 0 for name in sim.pct}
    decisions, refused_historical, held, behind_placements = [], 0, 0, 0
    lowest = dict(sim.pct)
    while queue and queue[0]["due"] <= end:
        start = queue.pop(0)
        sim.advance(start["due"])
        for name in lowest:
            lowest[name] = min(lowest[name], sim.pct[name])
        if mode == "historical":
            sim.place(start["historical"].split(":")[0])
            placed[start["historical"].split(":")[0]] += 1
            continue
        result, verdict = ask(root, home, remote, sim, start, brief)
        if verdict == "refused" and start["historical"].startswith("codex") and result.get("status") == "clear":
            refused_historical += 1
        if result.get("status") != "clear":
            held += 1
            queue.append({**start, "due": start["due"] + 900})
            queue.sort(key=lambda s: s["due"])
            continue
        provider = ALLOWANCE[(result["chosen"]["home"], result["chosen"]["provider"])]
        # Judged as the resolver sees it: headroom less the draw still owed.
        heads = {name: sim.headroom(name, charged=True) for name in sim.pct}
        usable = [heads[name] for name in heads if sim.pct[name] >= 10]
        if max(usable) - heads[provider] > 20:
            behind_placements += 1
        decisions.append({"t": sim.now - sim.start, "chosen": provider, "headroom": heads})
        if os.environ.get("REPLAY_TRACE"):
            print(json.dumps({"t": round((sim.now - sim.start) / 3600, 2), "chosen": provider,
                              "pct": {k: round(v, 1) for k, v in sim.pct.items()}}), file=sys.stderr)
        sim.place(provider, result["chosen"]["home"])
        placed[provider] += 1
    sim.advance(end)
    for name in lowest:
        lowest[name] = min(lowest[name], sim.pct[name])
    final = {name: round(sim.pct[name], 1) for name in sim.pct}
    heads = {name: sim.headroom(name) for name in sim.pct}
    print(json.dumps({"mode": mode, "placed": placed, "final_percent": final, "final_headroom": heads,
                      "lowest_percent": {k: round(v, 1) for k, v in lowest.items()},
                      "final_spread": round(max(heads.values()) - min(heads.values()), 1),
                      "behind_placements": behind_placements, "held": held,
                      "historical_codex_starts_refused": refused_historical, "unplaced": len(queue)}))


if __name__ == "__main__":
    main()
