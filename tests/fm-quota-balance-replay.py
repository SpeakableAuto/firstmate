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
        self.sequence = 0
        self.session = {name: 80.0 for name in self.pct if name.startswith("claude")}
        self.session_reset = {name: self.start + 5 * 3600 for name in self.session}
        self.samples = []
        self.minimum = dict(self.pct)
        self.minimum_session = dict(self.session)

    def next_reset(self, name):
        return min(r for r in self.resets[name] if r > self.now)

    def owed(self, name):
        return sum(c["rate"] * (c["end"] - self.now) for c in self.crews if c["provider"] == name)

    def headroom(self, name, charged=False):
        left = 100 * (self.next_reset(name) - self.now) / self.window[name]
        weekly = self.pct[name] - (self.owed(name) if charged else 0) - left
        if name in self.session:
            owed = sum(8 * (c["end"] - self.now) / (c["end"] - c["start"])
                       for c in self.crews if c["provider"] == name) if charged else 0
            short = self.session[name] - owed - 100 * (self.session_reset[name] - self.now) / (5 * 3600)
            return round(min(weekly, short), 2)
        return round(weekly, 2)

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
            for name in self.session:
                loss = sum(8 * max(0, min(step,c["end"]) - max(self.now,c["start"])) / (c["end"]-c["start"])
                           for c in self.crews if c["provider"] == name)
                self.session[name] = max(0, self.session[name] - loss - 2 * (step-self.now)/3600)
                if step >= self.session_reset[name]:
                    self.session[name] = 100
                    self.session_reset[name] += 5*3600
                self.minimum_session[name] = min(self.minimum_session[name], self.session[name])
            self.now = step
            for name in self.pct:
                self.minimum[name] = min(self.minimum[name], self.pct[name])
            self.samples.append((self.now, self.snapshot(), self.snapshot("claude_m0002"), list(self.crews)))
            self.crews = [c for c in self.crews if c["end"] > self.now]

    def place(self, provider, home="local", model="default"):
        self.sequence += 1
        run = self.draw[provider]["run_seconds"]
        self.crews.append({"task":str(self.sequence),"model":model,"provider": provider, "home": home, "start": self.now, "end": self.now + run,
                           "rate": self.draw[provider]["points_per_start"] / run})

    def snapshot(self, claude="claude"):
        def row(name, provider):
            weekly_id = "weekly" if provider == "codex" else "seven_day"
            weekly_head = self.pct[name] - 100 * (self.next_reset(name)-self.now)/self.window[name]
            windows = [{"id":weekly_id,"kind":"weekly","percentRemaining":round(self.pct[name],4),
                        "resetsAt":self.iso(self.next_reset(name)),"pace":{"reservePercentPoints":weekly_head}}]
            if provider == "claude":
                windows.append({"id":"five_hour","kind":"session","percentRemaining":round(self.session[name],4),
                                "resetsAt":self.iso(self.session_reset[name]+(self.now%3)/10),
                                "pace":{"reservePercentPoints":self.session[name]-100*(self.session_reset[name]-self.now)/(5*3600)}})
            limiting = min(windows, key=lambda w:w["percentRemaining"])["id"]
            scope = {"scope":"all_models","status":"known","effectivePercentRemaining":min(w["percentRemaining"] for w in windows),
                     "boundedBy":[w["id"] for w in windows],"limitingWindowIds":[limiting],
                     "pace":{"worstReservePercentPoints":self.headroom(name)},
                     "runway":{"status":"projected_exhaustion"},"selection":{"spendPriority":0}}
            scopes=[scope]
            if provider == "claude": scopes.append(dict(scope,scope="model:fable"))
            return {"provider":provider,"state":{"status":"fresh","stale":False},"windows":windows,
                    "quotaSemantics":{"status":"known","effectiveAvailability":scopes}}
        return {"schemaVersion":5,"providers":[row(claude,"claude"),row("codex","codex")]}

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
        for stale in list(state.glob("crew*.meta")):
            stale.unlink(missing_ok=True)
        samples = []
        for at, local_snap, remote_snap, crews in sim.samples:
            snapshot = local_snap if home_id == "local" else remote_snap
            rows = [{"provider":r["provider"],"account":"","windows":[
                {"window":w["id"],"pct":w["percentRemaining"],"resets":w["resetsAt"]} for w in r["windows"]]}
                    for r in snapshot["providers"]]
            observed = [{"task":c["task"],"provider":"codex" if c["provider"]=="codex" else "claude","model":c["model"]}
                        for c in crews if c["home"]==home_id]
            samples.append({"at":wall-(sim.now-at),"rows":rows,"crews":observed})
        (state/"quota-samples.jsonl").write_text("".join(json.dumps(r)+"\n" for r in samples))
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
                            "windows": {("weekly" if provider=="codex" else "seven_day"):{"draw":crew["rate"]*(crew["end"]-crew["start"]),"span":crew["end"]-crew["start"]},
                                        **({"five_hour":{"draw":8,"span":crew["end"]-crew["start"]}} if provider=="claude" else {})},
                            "span": crew["end"] - crew["start"]})
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
    process = subprocess.run([str(root / "bin/fm-dispatch-resolve.sh"), "--rule", RULE_OF[start["class"]],
                          "--check", harness, model, effort, str(brief), "--project", "app"],
                         env=env, capture_output=True, text=True)
    if process.returncode:
        raise RuntimeError(f"resolver exit {process.returncode}: {process.stderr}")
    result = json.loads(process.stdout.strip().splitlines()[-1])
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
    measured_placements = 0
    reserve_at_start = {name:100.0 for name in sim.pct}
    lowest = dict(sim.pct)
    while queue and queue[0]["due"] <= end:
        start = queue.pop(0)
        sim.advance(start["due"])
        for name in lowest:
            lowest[name] = min(lowest[name], sim.pct[name])
        if mode == "historical":
            sim.place(start["historical"].split(":")[0], model=start["historical"].split(":")[1])
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
        # Usable as the resolver judges it: room for one more crew's fixed draw
        # above the 10% reserve once in-flight draw is counted.
        usable = [heads[name] for name in heads
                  if (start["class"] != "design" or name.startswith("claude"))
                  and sim.pct[name] - sim.owed(name) - sim.draw[name]["points_per_start"] >= 10
                  and (name not in sim.session or sim.session[name] - sum(
                      8*(c["end"]-sim.now)/(c["end"]-c["start"]) for c in sim.crews if c["provider"]==name) - 8 >= 10)]
        if usable and max(usable) - heads[provider] > 20:
            behind_placements += 1
            print(json.dumps({"behind":provider,"class":start["class"],"heads":heads,"usable":usable}),file=sys.stderr)
        decisions.append({"t": sim.now - sim.start, "chosen": provider, "headroom": heads})
        if os.environ.get("REPLAY_TRACE"):
            print(json.dumps({"t": round((sim.now - sim.start) / 3600, 2), "chosen": provider,
                              "pct": {k: round(v, 1) for k, v in sim.pct.items()}}), file=sys.stderr)
        own = sim.draw[provider]["points_per_start"]
        reserve_at_start[provider] = min(reserve_at_start[provider],sim.pct[provider]-sim.owed(provider)-own)
        if (result["chosen"].get("burn") or {}).get("windows"): measured_placements += 1
        sim.place(provider, result["chosen"]["home"], result["chosen"]["profile"].get("model","default"))
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
                      "measured_placements":measured_placements,"reserve_at_start":reserve_at_start,"lowest_session":sim.minimum_session,
                      "historical_codex_starts_refused": refused_historical, "unplaced": len(queue)}))


if __name__ == "__main__":
    main()
