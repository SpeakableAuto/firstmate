#!/usr/bin/env python3
"""Placement data contract and atomic capacity ledger (no launch authority).

Usage: fm-placement.py assess CONFIG DATA ID HARNESS MODEL EFFORT
       fm-placement.py memory
       fm-placement.py worktree CONFIG PROJECT [WORKTREE]
       fm-placement.py reachable CONFIG PATH
       fm-placement.py record STATE ID [spawn|recheck]
       fm-placement.py waits STATE
       fm-placement.py drop STATE ID
       fm-placement.py due STATE
       fm-placement.py urgent PLACEMENT_JSON IMPACT
       fm-placement.py urgent-live DATA [ID...]
memory reads fresh operating-system memory/swap evidence; assess consumes JSON
evidence on stdin and prints a complete decision.
record consumes that decision; one replace publishes the decision and its wait
in state/capacity.json, under an exclusive ledger lock. This is the capacity log.
waits prints P0-P3, oldest-first waits, with over_four_hours computed at read time
for capacity waits, plus historical bottlenecks observed within the last 48h.
Those history rows never reenter dispatch; the ledger retains their evidence.
A fit refusal is 'unplaceable' (never a capacity wait);
a terminal decision or drop removes the wait.
due emits 'due' on a 900-second cadence or a changed resource fingerprint;
it never launches work. The watcher owns rechecks and normal wake delivery.
urgent prints yes or no for the reserved-slot rule (see urgent() below);
urgent-live counts the named live tasks it marks, from backlog JSON on stdin.
pool, assess and worktree read the machine drive and data volume only in a
child process (see bounded() below); FM_PLACEMENT_DRIVE_SECS (default 10) is
that read's deadline, after which placement refuses the drive and moves on.
reachable checks, under the same bound, that a task copy recorded under the
machine drive still answers (relaunch calls it before touching that copy);
a path outside the drive is not read at all.
FM_PLACEMENT_ATTEMPT_MEMO names one attempt's note (fm-spawn.sh and
fm-dispatch-resolve.sh set it): once a read times out, later reads in the same
attempt refuse at once instead of waiting their own deadline.
"""

import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
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
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def urgent(work, impact):
    """Only Firstmate's own marks make work urgent: backlog impact P0, or an
    explicit placement.json impact P0 or "urgent": true written after triage.
    A reporter's urgency label in titles or brief text never counts."""
    work = work if isinstance(work, dict) else {}
    return impact == "P0" or work.get("impact") == "P0" or work.get("urgent") is True


def room_limit(cap, is_urgent, urgent_live=0):
    """Ordinary work leaves the last crew slot free for one urgent task; a
    live urgent task fills that reserve, not one of the cap - 1 ordinary slots."""
    if is_urgent or cap < 2:
        return cap
    return min(cap, cap - 1 + (urgent_live if type(urgent_live) is int and urgent_live > 0 else 0))


def urgent_live(data, tasks, records):
    """Count live tasks carrying Firstmate's urgent mark."""
    impacts = {row.get("id"): row.get("impact") for row in records if isinstance(row, dict)}
    total = 0
    for task in tasks:
        work = data / task / "placement.json"
        try:
            value = read(work) if work.is_file() and not work.is_symlink() else {}
        except (OSError, ValueError):
            value = {}
        total += urgent(value, impacts.get(task) or "P2")
    return total


def result(passed, reason):
    return {"status": "pass" if passed else "fail", "reason": reason}


def failure(reason, condition):
    return dict(result(False, reason), condition=condition, alert=True)


DRIVE_SECS = 10
DRIVE_UNAVAILABLE = "required machine drive unavailable"


class Stalled(Exception):
    """A drive or volume read did not finish within its deadline."""


def drive_seconds():
    try:
        value = float(os.environ.get("FM_PLACEMENT_DRIVE_SECS", ""))
    except ValueError:
        return DRIVE_SECS
    return value if math.isfinite(value) and value > 0 else DRIVE_SECS


def bounded(probe, *args):
    """Run one drive-touching read in a child process with a deadline.

    A stalled drive can hold stat, statvfs, access or open in the kernel with
    no timeout, so only the child ever makes those reads. On the deadline the
    child's own group is killed, the reap waits at most one second, and an
    unkillable child is abandoned: it holds no descriptor of this process's
    caller, so a command substitution around this command still returns.
    """
    memo = os.environ.get("FM_PLACEMENT_ATTEMPT_MEMO", "")
    if memo and os.path.exists(memo):
        raise Stalled("skipped: the drive did not answer an earlier check in this attempt")
    deadline = drive_seconds()
    child = subprocess.Popen([sys.executable, os.path.abspath(__file__), "probe", probe],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             cwd="/", start_new_session=True)
    try:
        out, _ = child.communicate(json.dumps(args).encode(), timeout=deadline)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            child.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        for stream in (child.stdin, child.stdout):
            try:
                stream.close()
            except OSError:
                pass
        if memo:
            try:
                open(memo, "a").close()
            except OSError:
                pass
        raise Stalled(f"did not finish within {deadline:g}s") from None
    try:
        answer = json.loads(out)
    except ValueError:
        raise OSError(f"drive check exited {child.returncode} without a result") from None
    if "error" in answer:
        kind = {"KeyError": KeyError, "TypeError": TypeError, "OSError": OSError}.get(answer.get("type"), ValueError)
        raise kind(answer["error"])
    return answer["value"]


def drive_ready(drive):
    drive = Path(drive)
    return real_directory(drive) and drive.is_mount() and os.access(drive, os.W_OK)


def reach(path):
    """Touch a task copy the way a relaunch first does: stat, list, its .git."""
    os.stat(path)
    os.listdir(path)
    os.path.lexists(os.path.join(path, ".git"))
    return True


def reachable(config, target):
    """A recorded task copy under the machine drive must answer within the bound.

    The comparison is lexical, so a copy outside the drive costs no read; a
    relative or symlinked spelling outside the drive is not checked.
    """
    path = config / "crew-placement.json"
    drive = read(path).get("drive") if path.exists() else None
    if not drive:
        return result(True, "no machine drive configured")
    root = os.path.normpath(drive)
    spelled = os.path.normpath(target) if os.path.isabs(target) else ""
    if spelled and spelled != root and not spelled.startswith(root.rstrip("/") + "/"):
        return result(True, f"not on the machine drive: {target}")
    try:
        bounded("reach", target)
    except Stalled as stalled:
        return failure(f"{DRIVE_UNAVAILABLE}: {drive} (task copy {target} check {stalled})", f"stalled:{drive}")
    except (OSError, ValueError, KeyError, TypeError) as error:
        return result(True, f"task copy read finished: {error}")
    return result(True, f"task copy answers: {target}")


def free_gib(path):
    stat = os.statvfs(path)
    return stat.f_bavail * stat.f_frsize / 1024**3


def probe(name):
    """Child side of bounded(): JSON arguments on stdin, one JSON answer out."""
    function = {"external": external_checks, "treehouse": treehouse_root,
                "drive": drive_ready, "free": free_gib, "reach": reach}[name]
    try:
        answer = {"value": function(*json.load(sys.stdin))}
    except (OSError, ValueError, KeyError, TypeError) as error:
        kind = next(k.__name__ for k in (KeyError, TypeError, OSError, ValueError) if isinstance(error, k))
        answer = {"error": error.args[0] if kind == "KeyError" and error.args else str(error), "type": kind}
    print(json.dumps(answer, separators=(",", ":"), allow_nan=False))


def stalled_external(profile, project, error):
    """The refusal for a drive that stopped answering: one alert, for the drive."""
    drive = profile.get("drive")
    if drive is None:
        return {}
    unavailable = f"{DRIVE_UNAVAILABLE}: {drive} (drive checks {error})"
    return {"drive": failure(unavailable, f"stalled:{drive}"),
            "data-disk": result(False, f"data volume not measured: {unavailable}"),
            "treehouse-root": result(False, f"treehouse-root: not checked for {project} (drive unavailable)")}


def real_directory(path):
    return path.is_absolute() and path.is_dir() and str(path.resolve()) == str(path)


def write_probe(path):
    fd, probe = tempfile.mkstemp(prefix=".fm-placement-", dir=path)
    try:
        os.close(fd)
    finally:
        os.unlink(probe)


def external_checks(profile, project, worktree=None):
    """No directory creation and no internal fallback; probes remove only themselves."""
    drive = profile.get("drive")
    if drive is None:
        return {}
    checks = {}
    path = Path(drive)
    mounted = real_directory(path) and path.is_mount()
    checks["drive"] = (result(True, f"real mount: {path}") if mounted else
                       failure(f"drive unmounted or symlinked: {path}", f"unmounted:{path}"))
    dirs = profile.get("required_drive_dirs")
    if not isinstance(dirs, list) or not dirs or not all(isinstance(d, str) and d for d in dirs):
        checks["drive-dirs"] = failure("required_drive_dirs absent or invalid", "missing-directory-list")
    elif mounted:
        for relative in dirs:
            target = path / relative
            key = f"drive-dir:{relative}"
            if Path(relative).is_absolute() or ".." in Path(relative).parts or not real_directory(target):
                checks[key] = failure(f"required directory missing or symlinked: {target}", f"missing:{target}")
                continue
            try:
                write_probe(target)
                checks[key] = result(True, f"write probe cleaned: {target}")
            except OSError:
                checks[key] = failure(f"required directory unwritable: {target}", f"unwritable:{target}")
        try:
            write_probe(path)
        except OSError:
            checks["drive"] = failure(f"drive unwritable: {path}", f"unwritable:{path}")
    volume = profile.get("data_volume")
    if not isinstance(volume, dict):
        checks["data-disk"] = failure("data_volume measurement configuration absent", "missing-data-volume")
    else:
        try:
            internal = Path(volume["path"])
            floor = volume["min_free_gib"]
            if type(floor) not in (int, float) or not math.isfinite(floor) or floor <= 0:
                raise ValueError("invalid data_volume.min_free_gib")
            if not real_directory(internal):
                raise ValueError("data volume path missing or symlinked")
            stat = os.statvfs(internal)
            free = stat.f_bavail * stat.f_frsize / (1024 ** 3)
            checks["data-disk"] = (result(True, f"{internal}: {free:.3f} GiB >= {floor:g} GiB") if free >= floor else
                                   failure(f"data volume below floor: {internal}: {free:.3f} GiB < {floor:g} GiB",
                                           f"below-floor:{internal}"))
        except (OSError, ValueError, KeyError, TypeError) as error:
            checks["data-disk"] = failure(f"data volume measurement absent: {error}", "missing-data-measurement")
    checks["treehouse-root"] = treehouse_root(profile, project, worktree)
    # A pool root on an unavailable drive fails as a consequence of the drive
    # check; keep it named in the refusal but alert once, for the drive itself.
    if checks["drive"]["status"] != "pass" and checks["treehouse-root"]["status"] != "pass":
        checks["treehouse-root"] = result(False, checks["treehouse-root"]["reason"] + " (drive unavailable)")
    return checks


def treehouse_root(profile, project, worktree=None):
    if profile.get("drive") is None:
        return result(True, "external pool not required")
    try:
        project = Path(project)
        config = project / "treehouse.toml"
        if not config.is_file() or config.is_symlink():
            raise ValueError("repo-local treehouse.toml missing or symlinked")
        # Python 3.9 remains supported. Accept a narrow literal top-level
        # configuration, refusing complex TOML rather than guessing its root.
        settings = {}
        for line in config.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("["):
                break
            match = re.fullmatch(r"([A-Za-z_][A-Za-z_0-9-]*)\s*=\s*(.*)", line)
            if not match:
                raise ValueError("unsupported top-level Treehouse configuration")
            key, raw = match.groups()
            if key in settings:
                raise ValueError("duplicate Treehouse setting")
            if key in ("root", "worktree_path"):
                literal = re.fullmatch(r"('([^']*)'|\"(?:[^\"\\]|\\.)*\")\s*(?:#.*)?", raw)
                if not literal:
                    raise ValueError("Treehouse root/layout must be a literal string")
                settings[key] = literal[2] if raw.startswith("'") else json.loads(literal[1])
            elif '\"\"\"' in raw or "'''" in raw:
                raise ValueError("multiline Treehouse configuration is unsupported")
            else:
                settings[key] = raw
        declared = settings.get("root")
        if not isinstance(declared, str) or not declared:
            raise ValueError("repo-local Treehouse root absent")
        # Require an absolute literal: no HOME, environment, or relative fallback.
        root = Path(declared)
        drive = Path(profile["drive"])
        if not real_directory(root) or not root.is_relative_to(drive):
            raise ValueError("Treehouse root missing, symlinked, or outside required drive")
        if (root / ".treehouse").is_symlink():
            raise ValueError("Treehouse pool is symlinked")
        # Reject custom layouts: Treehouse may restore existing slot paths too,
        # so acquired path verification remains mandatory even for this layout.
        if settings.get("worktree_path"):
            raise ValueError("custom worktree_path cannot prove external allocation")
        if worktree is not None:
            target = Path(worktree)
            if not real_directory(target) or target == root or not target.is_relative_to(root):
                raise ValueError("acquired worktree is outside the real external pool")
        return dict(result(True, f"external Treehouse root: {root}"), root=str(root))
    except (OSError, ValueError, TypeError) as error:
        return failure(f"treehouse-root: {error}", f"treehouse-root:{project}:{error}")


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
    impact = evidence.get("impact")
    decision = {"task": task, "impact": impact if impact in ("P0", "P1", "P2", "P3") else "P2",
                "request": request, "checks": checks}
    for name in ("quota", "locks"):
        value = evidence.get(name)
        if isinstance(value, dict) and value.get("status") in ("pass", "fail"):
            checks[name] = value
    machine = work = None
    try:
        profile = read(config / "crew-placement.json")
        if not isinstance(profile, dict) or profile.get("version") != 1:
            raise ValueError("machine profile must be a version 1 object")
        machine = profile
        work = read(data / task / "placement.json")
        if not isinstance(work, dict) or work.get("version") != 1:
            raise ValueError("task classification must be a version 1 object")
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
        matches = sum(c.get("harness") == harness and c.get("model", "") == model
                      and c.get("effort", "") == effort for c in candidates)
        quota_evidence = evidence.get("quota", {})
        balance = quota_evidence.get("balance", {}) if isinstance(quota_evidence, dict) else {}
        balance = balance if isinstance(balance, dict) else {}
        requested = balance.get("requested", {})
        requested = requested if isinstance(requested, dict) else {}
        charge = balance.get("charge", {})
        charge = charge if isinstance(charge, dict) else {}
        override = work.get("balance_override")
        admitted_override = (
            isinstance(override, str) and override != ""
            and balance.get("verdict") == "override"
            and balance.get("override") == override
            and requested.get("harness") == harness
            and requested.get("model", "") == model
            and requested.get("effort", "") == effort
            and charge.get("home") == "local"
            and charge.get("provider") == requested.get("provider")
            and charge.get("account", "") == requested.get("account", "")
            and charge.get("model", "") == model
        )
        if matches != 1 and not admitted_override:
            raise ValueError("selected model is outside the task-fit dispatch rule")
        checks["fit"] = result(True, f"workload={workload}; dispatch_rule={rule}"
                               + ("; balance_override=admitted" if admitted_override else ""))
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        checks["fit"] = result(False, str(error))
    profile = machine
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
            if evidence.get("crew_liveness"):
                raise ValueError(evidence["crew_liveness"])
            count = evidence.get("crew_count")
            if type(count) is not int or count < 0 or count >= cap:
                raise ValueError(f"crew cap: count={count}, cap={cap}")
            # A relaunch resumes a task that already held its slot.
            if (evidence.get("relaunch") is not True
                    and count >= room_limit(cap, urgent(work, evidence.get("impact")), evidence.get("urgent_live"))):
                raise ValueError(f"crew cap: count={count}, cap={cap}; last slot reserved for urgent work")
            free, swap = evidence.get("memory", {}).get("free_percent"), evidence.get("memory", {}).get("swap_mib")
            if not all(type(v) in (int, float) and math.isfinite(v) and v >= 0 for v in (free, swap)):
                raise ValueError("memory pressure or swap evidence absent")
            if free < floor or swap > swap_cap:
                raise ValueError(f"memory: free={free:g}%, swap={swap:g} MiB")
            disk = evidence.get("disk", {})
            if disk.get("status") != "pass":
                raise ValueError("disk floor absent or failed")
            checks["room"] = result(True, f"crew={count}/{cap}; free={free:g}%; swap={swap:g} MiB")
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            checks["room"] = result(False, str(error))
        checks["slots"] = evidence.get("slots", result(False, "slots evidence absent"))
        if checks["slots"].get("status") == "not-installed":
            checks["slots"] = result(False, "slot room seam absent")
        try:
            checks.update(bounded("external", profile, evidence.get("project", "")))
        except Stalled as stalled:
            checks.update(stalled_external(profile, evidence.get("project", ""), stalled))
        except (ValueError, TypeError, OSError) as error:
            checks["drive"] = failure(f"external placement configuration invalid: {error}", "invalid-external-config")
    decision["failed"] = [key for key, value in checks.items() if value["status"] != "pass"]
    decision["admitted"] = not decision["failed"]
    return decision


def remember_bottlenecks(value, now):
    """Capture elapsed capacity waits before admission/hold/drop erases them."""
    changed = False
    for row in value["waits"].values():
        if row["state"] not in ("capacity", "ready") or now - row["since"] <= 14400:
            continue
        key = f'{row["task"]}:{row["since"]}'
        events = value.setdefault("bottlenecks", {})
        previous = events.get(key, {})
        event = dict(row, state="history", over_four_hours=True,
                     wait_seconds=now - row["since"], observed_at=now,
                     # A successful recheck clears failed; keep the refusal
                     # that explains the already-observed bottleneck.
                     failed=row["failed"] or previous.get("failed", []))
        if previous != event:
            events[key] = event
            changed = True
    return changed


def ledger(state, operation, task=None, mode=None):
    state.mkdir(parents=True, exist_ok=True)
    with open(state / ".capacity-ledger.lock", "a", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = state / "capacity.json"
        value = read(path) if path.exists() else {"version": 1, "decisions": [], "waits": {}}
        now = int(time.time())
        remembered = remember_bottlenecks(value, now)
        if remembered and operation not in ("record", "amend", "hold", "drop"):
            atomic(path, value)
        if operation in ("record", "amend"):
            decision = json.load(sys.stdin)
            if decision.get("task") != task or mode not in ("spawn", "recheck"):
                raise ValueError("invalid decision identity")
            if operation == "amend":
                matches = [i for i, row in enumerate(value["decisions"])
                           if row["id"] == decision.get("id") and row["task"] == task]
                if len(matches) != 1:
                    raise ValueError("original decision absent or ambiguous")
                decision["updated_at"] = now
                value["decisions"][matches[0]] = decision
            else:
                decision.update(at=now, id=uuid.uuid4().hex, mode=mode)
                value["decisions"].append(decision)
            alerts = value.setdefault("alerts", {})
            for key, check in decision["checks"].items():
                identity = key
                if key in ("treehouse-root", "acquired-worktree"):
                    identity += ":" + decision["request"].get("project", task)
                if check.get("alert") and check["status"] != "pass":
                    if alerts.get(identity, {}).get("condition") != check["condition"]:
                        alerts[identity] = dict(check, token=uuid.uuid4().hex, pending=True, task=task)
                elif check["status"] == "pass":
                    alerts.pop(identity, None)
            old = value["waits"].get(task, {})
            if decision.get("hold") or decision.get("terminal"):
                value["waits"].pop(task, None)
            elif decision["admitted"] and mode == "spawn":
                value["waits"].pop(task, None)
            else:
                value["waits"][task] = {
                    "task": task, "since": now if old.get("state") == "hold" or (old.get("state") == "wip" and decision["failed"] != ["finish-first"]) else old.get("since", now), "checked": now,
                    "impact": decision["impact"], "failed": decision["failed"],
                    "request": decision["request"],
                    "state": "ready" if decision["admitted"] else
                             "unplaceable" if "fit" in decision["failed"] else
                             "wip" if decision["failed"] == ["finish-first"] else "capacity",
                }
            atomic(path, value)
            return decision
        if operation == "hold":
            if task in value["waits"]:
                value["waits"][task].update(state="hold", hold=mode)
            if task in value["waits"] or remembered:
                atomic(path, value)
            return True
        if operation == "drop":
            if value["waits"].pop(task, None) is not None or remembered:
                atomic(path, value)
            return True
        if operation == "alerts":
            return [dict(alert, key=key) for key, alert in value.get("alerts", {}).items() if alert["pending"]]
        if operation == "ack-alert":
            alert = value.get("alerts", {}).get(task)
            if alert and alert["token"] == mode:
                alert["pending"] = False
                atomic(path, value)
            return True
        if operation in ("waits", "ordered"):
            impacts, order = {}, {}
            if operation == "ordered":
                records = json.load(sys.stdin)["records"]
                impacts = {row["id"]: row.get("impact") or "P2" for row in records}
                order = {row["id"]: (row["state"] != "in_flight", row.get("since") or "9999-99-99", row["order"])
                         for row in records}
            history = []
            for event in value.get("bottlenecks", {}).values():
                current = value["waits"].get(event["task"], {})
                still_waiting = (current.get("since") == event["since"]
                                 and current.get("state") in ("capacity", "ready"))
                if not still_waiting and now - event["observed_at"] <= 172800:
                    history.append(event)
            rows = [dict(row, impact=impacts.get(row["task"], row.get("impact", "P2")),
                                over_four_hours=row["state"] in ("capacity", "ready") and now - row["since"] > 14400)
                    for row in value["waits"].values()] + history
            # Undated queued work falls back to wait age before backlog position.
            def rank(row):
                carried, dated, position = order.get(row["task"], (True, "9999-99-99", 0))
                return (row["impact"], carried, dated, row["since"], position, row["task"])
            return sorted(rows, key=rank)
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


def pool(config, count, live_urgent=0):
    """Read-only machine fit/room evidence for the quota resolver pool."""
    path = config / "crew-placement.json"
    if not path.exists():
        return {"configured": False, "available": True}
    try:
        profile = read(path)
        cap = profile["max_crew"]
        if type(cap) is not int or not 1 <= cap <= 4:
            raise ValueError("invalid machine crew cap")
        if count < 0 or count >= cap:
            raise ValueError(f"machine crew cap: {count}/{cap}")
        # Remote evidence is task-independent; the resolver applies urgent().
        reserved_only = count >= room_limit(cap, False, live_urgent)
        free, swap = memory()
        if free < profile["min_free_memory_percent"] or swap > profile["max_swap_mib"]:
            raise ValueError("machine memory or swap limit")
        if profile.get("drive"):
            try:
                ready = bounded("drive", profile["drive"])
            except Stalled as stalled:
                raise ValueError(f"{DRIVE_UNAVAILABLE} (drive check {stalled})") from None
            if not ready:
                raise ValueError(DRIVE_UNAVAILABLE)
        volume = profile.get("data_volume")
        if volume:
            try:
                free = bounded("free", volume["path"])
            except Stalled as stalled:
                raise ValueError(f"machine disk measurement unavailable (data volume check {stalled})") from None
            if free < volume["min_free_gib"]:
                raise ValueError("machine disk below floor")
        return {"configured": True, "available": True, "profile": profile, "crew_count": count,
                "reserved_only": reserved_only}
    except (OSError, ValueError, KeyError, TypeError) as error:
        return {"configured": True, "available": False, "reason": str(error)}


def main():
    operation, *args = sys.argv[1:]
    if operation == "probe":
        probe(*args)
        return
    if operation == "pool":
        output = pool(Path(args[0]), int(args[1]), int(args[2]) if len(args) > 2 else 0)
    elif operation == "urgent":
        path, impact = args
        work = read(Path(path)) if Path(path).is_file() else {}
        print("yes" if urgent(work, impact) else "no")
        return
    elif operation == "urgent-live":
        records = json.load(sys.stdin).get("records", [])
        print(urgent_live(Path(args[0]), args[1:], records if isinstance(records, list) else []))
        return
    elif operation == "memory":
        free, swap = memory()
        output = {"free_percent": free, "swap_mib": swap}
    elif operation == "worktree":
        config, project, *worktrees = args
        if len(worktrees) > 1:
            raise ValueError("worktree accepts CONFIG PROJECT [WORKTREE]")
        profile = read(Path(config) / "crew-placement.json")
        try:
            output = bounded("treehouse", profile, project, worktrees[0] if worktrees else None)
        except Stalled as stalled:
            output = failure(f"treehouse-root: {DRIVE_UNAVAILABLE}: {profile.get('drive')} (pool root check {stalled})",
                             f"treehouse-root:{project}:stalled")
    elif operation == "reachable":
        config, target = args
        output = reachable(Path(config), target)
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
