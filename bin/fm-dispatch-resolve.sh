#!/usr/bin/env bash
# fm-dispatch-resolve.sh - resolve one concrete crewmate or scout dispatch
# profile, and the machine that runs it, from a task brief with typesafe.ai's
# System One model (Jev), opt-in.
#
# Usage:
#   fm-dispatch-resolve.sh <brief-file> [--project <name>]
#   fm-dispatch-resolve.sh <brief-file> [--project <name>] <brief-file> [--project <name>] ...
#
# Each --project names the project of the brief just before it; one given
# before the first brief names that first brief's project. Several briefs are
# one batch: each is answered in order, and every placement is charged against
# its account before the next brief is placed. Placements stay charged for
# later calls through state/dispatch-charges.jsonl for the charge window
# docs/configuration.md "Charging placements" owns; each record names the
# selected model and applicable quota scopes. One brief is a batch of one.
#
# Opt-in gate: TYPESAFE_API_KEY non-empty in this process environment, else a
#   TYPESAFE_API_KEY= line in $FM_HOME/.env read with fmx_env_get, the same
#   accessor as FMX_PAIRING_TOKEN (bin/fm-env-lib.sh). The environment wins.
#   Absent in both: one "dispatch-resolve: off" line on stderr, nothing on
#   stdout, exit 0, no network call, so firstmate dispatches exactly as today.
#   The key lives in one shell variable and reaches curl as a header read from
#   a file descriptor, never on argv; nothing logs or writes it.
#
# What it does when on with at least one rule: one POST to
#   https://api.typesafe.ai/v1/systemone with the project name and the brief's
#   `## Captain's intent` and `## Firstmate spec` sections, tagged when it is a
#   scout brief (the whole brief when it has neither section), as state and
#   ONE Choice question whose options are every rule's `when` from
#   config/crew-dispatch.json plus one fixed generic none option. Jev returns
#   the matched rule, a probability per option, and a confidence. Everything
#   after that is jq: the confidence floor (0.6 on the answer confidence, or a
#   rule's declared `min_confidence` on that rule's probability, falling to the
#   most probable other option that clears its own floor), the rule's declared
#   `approval` and `floor`, each profile's declared `provider` and `floor`, the
#   quota rows from a quota-axi --json snapshot (schema 5 or 6; each
#   candidate binds to one row through quota_row in
#   bin/fm-quota-axi-lib.sh, so a Pi lane such as openai-codex-work/...
#   reads its own account's row and an expanded provider with no row for the
#   candidate is unmeasured, never blocked), the Claude crew guard each
#   machine's spawn admission enforces, and the configured selection among
#   eligible candidates of every machine in the pool (quota ranking by
#   default, candidate order by opt-in).
#   The model never sees quota, catalogs, approvals, selection policy, confidence
#   floors, `why`, or `use`. With no rules, it returns a non-clear
#   result so firstmate keeps using the existing intake.
#   docs/configuration.md "Crew dispatch profiles" owns the declared fields and
#   "Typed dispatch resolution" owns this tool's operator contract.
#
# Never-send check: when the optional $FM_HOME/config/dispatch-never-send list
#   exists, every string value of the built request is checked against it
#   before the POST. Each non-blank, non-# line is a literal matched
#   case-insensitively, with surrounding whitespace trimmed and every run of
#   whitespace, on both sides, treated as one space. A match, or a list that
#   is not a readable regular file, prints one
#   "dispatch-resolve: off (...; nothing sent)" line on stderr naming at most
#   the list line number, never its value, prints nothing on stdout, and exits
#   0 with no network or quota call, exactly like the absent-key off path.
#   In a batch that brief instead prints a block with status off and the same
#   reason, and the other briefs proceed.
#
# Output (stdout, one TOON-style block per brief):
#   dispatch-resolve:
#     brief: <path>  project: <name>   (batch only)
#     status: clear | ambiguous | escalate | error | off (batch only)
#     model/latency_ms/tokens, rule (when excerpt) and confidence, probabilities
#     fallback: <runner-up rule taken when the picked rule missed its own floor>
#     reason: <why the status is not clear>
#     selection: quota-balanced | candidate-order
#     candidate: [home=<id>] <harness>:<model> provider=.. scope=.. remaining=..% spendPriority=.. runway=.. [feed=..s old] [charged=<n> recent placement(s)] -> eligible | eligible, runway unknown: disclosed uncertainty | eligible, unranked: <reason> | not eligible: <reason>
#     passed over: [home=<id>] <harness>:<model>: projected to run out before reset; <later eligible candidate | another eligible candidate in the pool> has runway through_reset
#     near-tie broken by configured order: [home=<id>] <harness>:<model>=<spendPriority>, ... (within <band>)   (quota-balanced only)
#     exact cross-home tie: <candidates and worker counts> -> <winner> by <fewer live workers | stable task-key hash>
#     profile: --harness <h> [--model <m>] [--effort <e>] [--profile-floor-scope <scope> --profile-floor-min-percent <percent>]     (status clear only)
#     placement: local | secondmate <id> (<machine> <harness>:<model> <why>)   (pooled only)
#     home: <id> claude-crew=<n>/<cap> [+<n> recent placement(s)] session=..% [cached=..s old] | home: <id> not eligible: <reason> | home: <id> unknown: <reason>: disclosed uncertainty   (pooled only)
#   then, for a batch, one closing block:
#   dispatch-batch:
#     briefs: <n>   clear: <n>   other: <n>
#     machine: local=<n> <id>=<n> ...   provider: <provider>=<n> ...
#     profile: <machine>:<harness>:<model>=<n> ...
#   clear     -> pass the profile line to fm-spawn.sh unless you state a reason to override
#   ambiguous -> confidence below the floor; decide as today from the probabilities
#   escalate  -> the rule requires captain approval or no candidate is rankable
#   error     -> API, network, response, or quota-axi failure; decide as today
#   The pool is this machine plus every remote route in data/secondmates.md
#   whose projects name the brief's --project, unless this home registered the
#   project local-only. This machine leaves the pool when the project is not
#   in its own registry but a remote route lists it. Each remote machine's
#   quota and Claude crew evidence come from one bin/fm-quota-snapshot.sh
#   --secondmate read per call; an unavailable local or remote machine is a
#   disclosed unknown home line and never blocks the others. Only an intake
#   with no usable machine snapshot retains the local quota error. With more than one machine in the
#   pool the result is pooled: candidates carry home=<id> for remote machines,
#   and placement and home lines follow the profile line. The
#   quota-array-dispatch skill owns the pool rule.
#   Every outcome exits 0 so an intake is never blocked by this tool.
#   Exit 2 only for a usage or configuration error (unreadable brief, an
#   existing unreadable rules file, malformed rules, or missing jq), which is
#   actionable, never selected around.
#
# Environment:
#   TYPESAFE_API_KEY is the only resolver-specific environment setting.
#
# Authority: this tool never replaces firstmate's judgment, quota-array-dispatch,
#   the captain-approval gate, or fm-spawn.sh validation; it publishes one
#   inspectable answer plus every candidate's evidence, in code.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-claude-admission-lib.sh
. "$SCRIPT_DIR/fm-claude-admission-lib.sh"

CONFIDENCE_FLOOR=0.6
TS_MODEL=jev-latest
TS_BASE=https://api.typesafe.ai
TS_TIMEOUT=5
DEFAULT_WHEN="No listed rule applies to this task."

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
# A batch prints which brief and project each block answers; one brief prints
# exactly the single-brief block.
block_header() { # <index>
  [ "$BRIEF_COUNT" -gt 1 ] || return 0
  printf '  brief: %s\n' "$(printf '%s' "${BRIEFS[$1]}" | tr '\t\r\n' '   ')"
  [ -z "${PROJECTS[$1]}" ] || printf '  project: %s\n' "$(printf '%s' "${PROJECTS[$1]}" | tr '\t\r\n' '   ')"
}
no_rules() {
  local i
  for i in "${!BRIEFS[@]}"; do
    printf 'dispatch-resolve:\n'
    block_header "$i"
    printf '  status: escalate\n  reason: no rules to match\n'
  done
  exit 0
}
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

BRIEFS=() PROJECTS=() LEAD_PROJECT='' RULES_PATH="$CONFIG/crew-dispatch.json" RULES=''
NEVER_SEND_PATH="$CONFIG/dispatch-never-send"
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || die "--project needs a value"
      if [ "${#BRIEFS[@]}" -eq 0 ]; then
        [ -z "$LEAD_PROJECT" ] || die "--project given twice before the first brief"
        LEAD_PROJECT=$2
      else
        [ -z "${PROJECTS[${#BRIEFS[@]} - 1]}" ] || die "--project given twice for brief ${BRIEFS[${#BRIEFS[@]} - 1]}"
        PROJECTS[${#BRIEFS[@]} - 1]=$2
      fi
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) BRIEFS+=("$1"); PROJECTS+=(''); shift ;;
  esac
done
BRIEF_COUNT=${#BRIEFS[@]}
if [ -n "$LEAD_PROJECT" ] && [ "$BRIEF_COUNT" -gt 0 ]; then
  [ -z "${PROJECTS[0]}" ] || die "--project given twice for brief ${BRIEFS[0]}"
  PROJECTS[0]=$LEAD_PROJECT
fi

# ---- opt-in gate ---------------------------------------------------------------
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
fi
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  echo "dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env)" >&2
  exit 0
fi

# ---- inputs --------------------------------------------------------------------
[ "$BRIEF_COUNT" -gt 0 ] || die "brief file required (see --help)"
for brief in "${BRIEFS[@]}"; do
  [ -r "$brief" ] || die "brief file not readable: $brief"
done
[ -e "$RULES_PATH" ] || [ -L "$RULES_PATH" ] || no_rules
[ -r "$RULES_PATH" ] || die "rules file not readable: $RULES_PATH"
command -v jq >/dev/null 2>&1 || die "jq required"
RULES=$(mktemp) || die "mktemp failed"
trap 'rm -f "$RULES"' EXIT
cp "$RULES_PATH" "$RULES" || die "could not snapshot rules file: $RULES_PATH"
chmod 400 "$RULES" || die "could not protect rules snapshot"
VERIFIED_HARNESSES=$(fm_control_harnesses | jq -Rsc 'split("\n") | map(select(length > 0))')

# The fields this tool consumes must be well formed; bootstrap owns the wider
# schema diagnostic, but an intake never selects around a malformed file.
rules_err=$(jq -r --argjson verified_harnesses "$VERIFIED_HARNESSES" --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
  def verified($h): $verified_harnesses | index($h);
  def provider_id($p): ($p | type) == "string" and ($p | test($provider_re));
  def effort_ok($h; $m; $e):
    if $e == null then true
    elif ($e | type) != "string" then false
    elif $e == "ultra" then (($h == "pi" or $h == "pi-signed") and (($m | type) == "string") and ($m | startswith("codex-native/")) and ($m | length) > 13)
    elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "codex" then ((["low","medium","high","xhigh"] | index($e)) != null or ($e == "max" and $m == "gpt-5.6-luna"))
    elif $h == "grok" or $h == "agy" then (["low","medium","high"] | index($e)) != null
    elif $h == "pi" or $h == "pi-signed" or $h == "omp" or $h == "muse" then (["low","medium","high","xhigh","max"] | index($e)) != null
    elif $h == "rovo" then (["low","medium","high","max"] | index($e)) != null
    elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
    else true end;
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def floor_bad($f; $need_provider):
    ($f | type) != "object"
    or (($f.scope | type) != "string") or (($f.scope | length) == 0)
    or (($f.min_percent | type) != "number") or ($f.min_percent < 0) or ($f.min_percent > 100)
    or (if $need_provider
        then (provider_id($f.provider) | not)
        else ($f | has("provider"))
        end);
  def profile_bad($p):
    ($p | type) != "object"
    or (($p.harness | type) != "string") or (($p.harness | length) == 0)
    or ($p | has("model") and ((.model | type) != "string" or (.model | length) == 0))
    or ($p | has("effort") and ((.effort | type) != "string" or (.effort | length) == 0))
    or ($p | has("provider") and (provider_id(.provider) | not))
    or ($p | has("floor") and floor_bad(.floor; false));
  def duplicate_profiles($items):
    ($items | map([.harness, (.model // null), (.effort // null)] | @json)) as $keys
    | ($keys | length) != ($keys | unique | length);
  if type != "object" then "top-level value must be an object"
  elif has("rules") and (.rules | type) != "array" then "rules must be an array"
  elif any((.rules // [])[]; type != "object") then "each rule must be an object"
  elif any((.rules // [])[]; (.when | type) != "string" or (.when | length) == 0) then "each rule needs non-empty when"
  elif any((.rules // [])[]; (profiles(.use) | length) == 0) then "each rule needs at least one use profile"
  elif any((.rules // [])[]; has("approval") and .approval != "captain") then "approval must be \"captain\" when present"
  elif any((.rules // [])[]; has("min_confidence") and ((.min_confidence | type) != "number" or .min_confidence < 0 or .min_confidence > 1)) then "min_confidence must be a number from 0 through 1 when present"
  elif any((., (.rules // [])[]); has("select") and ((.select | type) != "string" or (.select | length) == 0)) then "select must be a non-empty string"
  elif any((., (.rules // [])[]); has("select") and (.select != "quota-balanced" and .select != "candidate-order")) then
    "unknown select: " + ([(., (.rules // [])[]) | select(has("select") and (.select != "quota-balanced" and .select != "candidate-order")) | .select] | unique | join(", "))
  elif any((.rules // [])[]; has("floor") and floor_bad(.floor; true)) then "rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\\z"
  elif any((.rules // [])[] | profiles(.use)[]; profile_bad(.)) then "each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif any((.rules // [])[]; duplicate_profiles(profiles(.use))) then "each rule use must not contain duplicate harness, model, and effort profiles"
  elif any((.rules // [])[] | profiles(.use)[]; (verified(.harness) | not)) then "each use profile must name a verified harness"
  elif any((.rules // [])[] | profiles(.use)[]; (effort_ok(.harness; .model; .effort) | not)) then "each use profile effort must be supported by its harness and model"
  elif has("default") and (profiles(.default) | length) == 0 then "default must be a profile object or non-empty profile array"
  elif has("default") and any(profiles(.default)[]; profile_bad(.)) then "each default profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
  elif has("default") and duplicate_profiles(profiles(.default)) then "default must not contain duplicate harness, model, and effort profiles"
  elif has("default") and any(profiles(.default)[]; (verified(.harness) | not)) then "each default profile must name a verified harness"
  elif has("default") and any(profiles(.default)[]; (effort_ok(.harness; .model; .effort) | not)) then "each default profile effort must be supported by its harness and model"
  else empty end
' "$RULES" 2>/dev/null) || die "malformed rules file: $RULES_PATH (not JSON)"
[ -z "$rules_err" ] || die "malformed rules file: $RULES_PATH - $rules_err"

missing_provider=$(jq -r '
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  ((.rules // [])[] | profiles(.use)[] | select(has("provider") | not) | "use\t\(.harness)"),
  (profiles(.default // null)[] | select(has("provider") | not) | "default\t\(.harness)")
' "$RULES" | while IFS=$'\t' read -r location harness; do
  if ! fm_quota_single_provider_for_harness "$harness" >/dev/null; then
    printf '%s\t%s\n' "$location" "$harness"
    break
  fi
done)
if [ -n "$missing_provider" ]; then
  IFS=$'\t' read -r location harness <<< "$missing_provider"
  die "malformed rules file: $RULES_PATH - $location profiles whose harness lacks one authoritative provider family require provider: $harness"
fi

# ---- harness -> provider map, from the single owner in fm-quota-axi-lib.sh -----
# The family map, from fm_control_harness_family, marks which candidates the
# Claude crew guard applies to.
PMAP='{}' FMAP='{}'
while IFS= read -r h; do
  [ -n "$h" ] || continue
  p=$(fm_quota_single_provider_for_harness "$h" 2>/dev/null) || p=''
  PMAP=$(jq -c --arg h "$h" --arg p "$p" '. + {($h): (if $p == "" then null else $p end)}' <<<"$PMAP")
  f=$(fm_control_harness_family "$h" 2>/dev/null) || f=''
  FMAP=$(jq -c --arg h "$h" --arg f "$f" '. + {($h): $f}' <<<"$FMAP")
done < <(jq -r '
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  ([((.rules // [])[]) | profiles(.use)[]] + profiles(.default // null))
  | map(.harness) | unique | .[]' "$RULES")

RULE_COUNT=$(jq -r '(.rules // []) | length' "$RULES")

# Per-brief work files live in one directory that the EXIT trap removes.
WORK=$(mktemp -d) || die "mktemp failed"
QUOTA="$WORK/quota.json"
SEND_TEXT="$WORK/send-text"
trap 'rm -rf "$RULES" "$WORK"' EXIT

[ "$RULE_COUNT" -gt 0 ] || no_rules

# Each brief ends in one result file: an error or off outcome written here, or
# the resolution written after the pool is evaluated.
brief_error() { # <index> <reason>
  echo "dispatch-resolve: error ($2)" >&2
  jq -nc --arg reason "$2" '{status: "error", reason: $reason}' > "$WORK/result.$1.json"
}
brief_off() { # <index> <reason>
  echo "dispatch-resolve: off ($2; nothing sent)" >&2
  jq -nc --arg reason "$2" '{status: "off", reason: $reason}' > "$WORK/result.$1.json"
}

# Checks every string the request carries, so no text reaches the network
# unchecked. grep's own stderr is discarded because it can echo the pattern.
# Sets NEVER_SEND_REASON and returns 1 when the request must not be sent.
never_send_check() { # <request-json>
  local list value n=0 rc
  NEVER_SEND_REASON=
  [ -e "$NEVER_SEND_PATH" ] || [ -L "$NEVER_SEND_PATH" ] || return 0
  if ! { [ -f "$NEVER_SEND_PATH" ] && [ -r "$NEVER_SEND_PATH" ]; }; then
    NEVER_SEND_REASON="$NEVER_SEND_PATH is not a readable regular file"
    return 1
  fi
  # Collapse whitespace runs on both sides so a value the brief wraps across
  # lines or spaces differently still matches
  if ! jq -r '.. | strings | gsub("\\s+"; " ")' <<<"$1" > "$SEND_TEXT" 2>/dev/null; then
    NEVER_SEND_REASON="could not extract the request text to check"
    return 1
  fi
  if ! list=$(jq -Rr 'gsub("\\s+"; " ")' "$NEVER_SEND_PATH" 2>/dev/null); then
    NEVER_SEND_REASON="could not read $NEVER_SEND_PATH"
    return 1
  fi
  while IFS= read -r value; do
    n=$((n + 1))
    value=${value# }
    value=${value% }
    case "$value" in
      ''|'#'*) continue ;;
    esac
    grep -qiF -e "$value" "$SEND_TEXT" 2>/dev/null; rc=$?
    case "$rc" in
      0) NEVER_SEND_REASON="brief text matches $NEVER_SEND_PATH line $n"; return 1 ;;
      1) ;;
      *) NEVER_SEND_REASON="could not check the request text against $NEVER_SEND_PATH line $n"; return 1 ;;
    esac
  done <<<"$list"
}

# Send Jev only the task-specific sections bin/fm-brief.sh scaffolds, plus a
# scout tag from the scout contract line; the rest of a scaffolded brief is
# standard boilerplate whose safety language reads as high stakes on every task.
# A brief with neither section goes whole. Ship delivery mode is deliberately
# not sent: live runs showed it pushing routine ship briefs to the top tier.
brief_kind() { # <brief>
  if grep -qxF 'This is a SCOUT task: the deliverable is a written report, not a PR.' "$1"; then
    printf 'Brief kind: scout (report only)\n\n'
  fi
}
task_sections() { # <brief>
  local heading
  for heading in "## Captain's intent" "## Firstmate spec"; do
    fm_brief_task_heading_present "$1" "$heading" || continue
    printf '%s\n%s\n\n' "$heading" "$(fm_brief_task_heading_body "$1" "$heading")"
  done
}

# One rule Choice per brief. Writes resp.<i>.json and lat.<i>, or the brief's
# error or off result.
ask_jev() { # <index>
  local i=$1 brief=${BRIEFS[$1]} sections request http t0 t1 lat
  local task_text="$WORK/task.$i" resp="$WORK/resp.$i.json"
  sections=$(task_sections "$brief")
  if [ -n "$sections" ]; then
    { brief_kind "$brief"; printf '%s\n' "$sections"; } > "$task_text" || die "could not read brief: $brief"
  else
    cp "$brief" "$task_text" || die "could not read brief: $brief"
  fi
  request=$(jq -n --rawfile brief "$task_text" --arg project "${PROJECTS[$i]}" --arg model "$TS_MODEL" \
    --arg none_criterion "$DEFAULT_WHEN" --slurpfile rules "$RULES" '
    ($rules[0]) as $cfg |
    ($cfg.rules | to_entries | map({key: ("rule_" + ((.key + 1) | tostring)), value: .value.when}) | from_entries) as $criteria |
    {
      model: $model,
      state: {task: {project: $project, brief: $brief}},
      questions: {
        rule: {
          type: "choice",
          instructions: "Which ONE dispatch rule best fits `task` (read `task.brief` and `task.project`)? Each option is the rule'"'"'s own matching condition; pick `default` when no rule'"'"'s condition is met, including when a rule'"'"'s own exemption text excludes this task.",
          criteria: ($criteria + {default: $none_criterion})
        }
      }
    }')
  if ! never_send_check "$request"; then
    brief_off "$i" "$NEVER_SEND_REASON"
    return 0
  fi
  t0=$(fm_timing_now_ms)
  http=$(printf '%s' "$request" | curl -sS --max-time "$TS_TIMEOUT" -o "$resp" -w '%{http_code}' \
    -X POST "$TS_BASE/v1/systemone" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
    --data-binary @- 2>/dev/null) || http=000
  t1=$(fm_timing_now_ms)
  lat=$(( t1 - t0 ))
  if [ "$http" != 200 ]; then
    brief_error "$i" "http $http after ${lat} ms: $(head -c 200 "$resp" 2>/dev/null | tr '\n' ' ')"
    return 0
  fi
  if ! jq -e --slurpfile rules "$RULES" '
      (($rules[0].rules | to_entries | map("rule_" + ((.key + 1) | tostring))) + ["default"] | sort) as $choices |
      (.answers.rule.choice | type) == "string" and
      (.answers.rule.confidence | type) == "number" and
      .answers.rule.confidence >= 0 and .answers.rule.confidence <= 1 and
      (.answers.rule.probabilities | type) == "object" and
      ((.answers.rule.probabilities | keys | sort) == $choices) and
      all(.answers.rule.probabilities[]; type == "number" and . >= 0 and . <= 1) and
      ((.answers.rule.probabilities | [.[]] | add) as $total | $total >= 0.99 and $total <= 1.01) and
      ((has("usage") | not) or
        ((.usage | type) == "object" and
         (.usage.input_tokens | type) == "number" and
         (.usage.output_tokens | type) == "number"))' \
    "$resp" >/dev/null 2>&1; then
    brief_error "$i" "response is not a rule Choice answer"
    return 0
  fi
  printf '%s\n' "$lat" > "$WORK/lat.$i"
}

# ---- rule answers: one model call per brief -----------------------------------
if command -v curl >/dev/null 2>&1; then
  for i in "${!BRIEFS[@]}"; do
    ask_jev "$i"
  done
else
  for i in "${!BRIEFS[@]}"; do
    brief_error "$i" "curl not installed"
  done
fi

# The rule answer: confidence floors, fallback, and the resolved choice. Every
# quota-dependent step comes later, once per pool.
for i in "${!BRIEFS[@]}"; do
  [ ! -e "$WORK/result.$i.json" ] || continue
  jq -n --arg floor "$CONFIDENCE_FLOOR" --argjson lat "$(cat "$WORK/lat.$i")" --arg none_criterion "$DEFAULT_WHEN" \
    --slurpfile resp "$WORK/resp.$i.json" --slurpfile rules "$RULES" '
    ($resp[0]) as $r | ($rules[0]) as $cfg | ($r.answers.rule) as $a |
    def rule_at($c):
      if ($c | test("^rule_[1-9][0-9]*$")) then
        ($c | ltrimstr("rule_") | tonumber) as $n |
        if $n <= (($cfg.rules // []) | length) then $cfg.rules[$n - 1] else null end
      else null end;
    def declared_confidence($c): rule_at($c) as $x | $x != null and ($x | has("min_confidence"));
    def confidence_floor($c): if declared_confidence($c) then rule_at($c).min_confidence else ($floor | tonumber) end;
    ($a.choice) as $picked |
    (confidence_floor($picked)) as $picked_floor |
    # A declared floor is checked against the probability of that option whether
    # it is the pick or a runner-up, so a runner-up never needs weaker support
    # than it would as the pick. Only a rule that declares its own floor falls
    # through to a runner-up, so a file with no declared floors keeps the single
    # global floor on the answer confidence exactly.
    (if declared_confidence($picked) | not then
       (if $a.confidence >= $picked_floor then {below: false} else {below: true, global: true} end)
     elif $a.probabilities[$picked] >= $picked_floor then {below: false}
     else
       ([$a.probabilities | to_entries[] | select(.key != $picked and .value >= confidence_floor(.key))]
         | sort_by(-.value)) as $ok |
       if ($ok | length) == 0 then {below: true, why: "no other option clears its own floor"}
       elif ($ok | length) > 1 and $ok[1].value == $ok[0].value then {below: true, why: "runner-up tie"}
       else {below: true, to: $ok[0].key, p: $ok[0].value, to_floor: confidence_floor($ok[0].key)} end
     end) as $fb |
    (if $fb.to then $fb.to else $picked end) as $choice |
    (rule_at($choice)) as $rule |
    def when_of($c): (if rule_at($c) == null then $none_criterion else rule_at($c).when end | .[0:60]);
    {
      model: $r.model, latency_ms: $lat, tokens: ($r.usage // null),
      rule: $picked, resolved_rule: $choice,
      rule_when: when_of($picked),
      confidence: $a.confidence, probabilities: $a.probabilities
    }
    + (if $fb.to then {fallback: "\($choice) (\(when_of($choice))) probability \($fb.p) clears its floor \($fb.to_floor); \($picked) probability \($a.probabilities[$picked]) is below its floor \($picked_floor)"} else {} end)
    + (if $choice != "default" and $rule == null then {kind: "error", reason: "rule \($choice) is not in the rules file"}
       elif $fb.below and $fb.global then {kind: "ambiguous", reason: "confidence \($a.confidence) below floor \($floor)"}
       elif $fb.below and ($fb.to | not) then {kind: "ambiguous", reason: "\($picked) probability \($a.probabilities[$picked]) below its floor \($picked_floor); \($fb.why)"}
       elif $rule != null and ($rule.approval // "") == "captain" then {kind: "approval", reason: "rule requires the captain'"'"'s explicit approval before dispatch"}
       else {kind: "resolve"} end)
  ' > "$WORK/answer.$i.json" 2>/dev/null || brief_error "$i" "resolution failed"
  if jq -e '.kind == "error"' "$WORK/answer.$i.json" >/dev/null 2>&1; then
    jq -c '. + {status: "error"} | del(.kind)' "$WORK/answer.$i.json" > "$WORK/result.$i.json"
  fi
done

pending() {
  local i
  for i in "${!BRIEFS[@]}"; do
    [ -e "$WORK/result.$i.json" ] || return 0
  done
  return 1
}

# ---- quota evidence: one bounded local snapshot read --------------------------
if pending; then
  quota_failure=
  if ! command -v quota-axi >/dev/null 2>&1; then
    quota_failure="quota-axi not installed"
  elif ! fm_quota_read_json "${FM_QUOTA_SNAPSHOT_TIMEOUT:-10}" quota-axi --json > "$WORK/live.json" 2>/dev/null; then
    quota_failure="quota-axi --json failed"
  elif ! fm_quota_json_valid < "$WORK/live.json"; then
    quota_failure="quota-axi --json returned an invalid snapshot"
  fi
  [ -z "$quota_failure" ] || : > "$WORK/live.json"
  # The home's optional quota feed fills unmeasured rows or stands in for a
  # failed read (docs/configuration.md "Quota snapshot reuse").
  if fm_quota_feed_merge "$CONFIG" "$WORK/live.json" > "$QUOTA"; then
    quota_failure=
  fi
  if [ -n "$quota_failure" ]; then
    printf 'null\n' > "$QUOTA"
    printf '%s\n' '{"unknown":"local quota unavailable"}' > "$WORK/local-admission.json"
  else
    fm_claude_admission_state "$CONFIG" "$STATE" "$QUOTA" > "$WORK/local-admission.json" 2>/dev/null \
      || printf '%s\n' '{"unknown":"Claude crew guard evidence failed"}' > "$WORK/local-admission.json"
  fi
fi

# ---- the pool: every machine that has the project ------------------------------
# This machine always joins the pool unless the project is registered only on
# remote second mates. A remote route joins when its registered projects name
# the project and this home has not registered the project local-only. Each
# remote machine's quota and Claude crew evidence come from one
# fm-quota-snapshot.sh --secondmate read per call (bounded, briefly cached);
# an unreachable machine is disclosed and never blocks the others.
remote_ids() { # <project>
  local project=$1 line entry mode
  local -a entries
  [ -n "$project" ] || return 0
  [ -f "$DATA/secondmates.md" ] && [ ! -L "$DATA/secondmates.md" ] || return 0
  mode=$("$SCRIPT_DIR/fm-project-mode.sh" "$project" 2>/dev/null) || return 0
  [ "${mode%% *}" != local-only ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] && [ -n "$SECONDMATE_REGISTRY_PROJECTS" ] || continue
    IFS=',' read -ra entries <<< "$SECONDMATE_REGISTRY_PROJECTS"
    for entry in "${entries[@]}"; do
      entry=${entry#"${entry%%[![:space:]]*}"}
      entry=${entry%"${entry##*[![:space:]]}"}
      if [ "$entry" = "$project" ]; then
        printf '%s\n' "$SECONDMATE_REGISTRY_ID"
        break
      fi
    done
  done < "$DATA/secondmates.md"
}

# Only a registry that exists and omits the project excludes this machine.
registered_here() { # <project>
  local warning
  warning=$("$SCRIPT_DIR/fm-project-mode.sh" "$1" 2>&1 >/dev/null) || return 0
  case "$warning" in
    *"not in registry"*) return 1 ;;
  esac
  return 0
}

remote_home() { # <id> -> remote.<id>.json, read once per call
  local id=$1 out="$WORK/remote.$1.json" snap="$WORK/remote.$1.snapshot" snap_err
  [ ! -e "$out" ] || return 0
  if snap_err=$("$SCRIPT_DIR/fm-quota-snapshot.sh" --secondmate "$id" 2>&1 >"$snap"); then
    jq -c --arg id "$id" '{id: $id, eligible: true, snapshot: .,
      admission: (.firstmateClaudeAdmission // null),
      cache_age: (.firstmateRemoteCache.ageSeconds // null)}' "$snap" > "$out"
  else
    snap_err=${snap_err#quota-snapshot: unavailable (}
    snap_err=${snap_err%)}
    jq -nc --arg id "$id" --arg reason "${snap_err:-quota unavailable}" \
      '{id: $id, eligible: true, snapshot: null, reason: $reason}' > "$out"
  fi
}

homes_for() { # <index> -> homes.<index>.json
  local i=$1 project=${PROJECTS[$1]} ids id local_eligible=true local_reason=''
  local -a files=()
  ids=
  ids=$(remote_ids "$project")
  if [ -n "$ids" ] && ! registered_here "$project"; then
    local_eligible=false
    local_reason="project $project is not registered on this machine"
  fi
  if [ -n "$quota_failure" ]; then
    jq -nc --arg reason "$quota_failure" \
      '{id: "local", eligible: true, snapshot: null, reason: $reason}' > "$WORK/home.$i.local.json"
  else
    jq -nc --argjson eligible "$local_eligible" --arg reason "$local_reason" \
      --slurpfile snapshot "$QUOTA" --slurpfile admission "$WORK/local-admission.json" '
      {id: "local", eligible: $eligible, snapshot: $snapshot[0], admission: $admission[0]}
      + (if $reason == "" then {} else {reason: $reason} end)' > "$WORK/home.$i.local.json"
  fi
  files+=("$WORK/home.$i.local.json")
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    remote_home "$id"
    files+=("$WORK/remote.$id.json")
  done <<<"$ids"
  jq -s . "${files[@]}" > "$WORK/homes.$i.json"
}

# Candidate evaluation against one snapshot bound to $q, with $pmap in scope.
# Every machine in the pool splices it in, so each is judged by exactly the
# same gates.
# shellcheck disable=SC2016  # jq program text, not shell expansion
CANDIDATE_JQ='
  def prov($p; $lane): quota_row($q; $p; $lane);
  def rows($p; $lane): (prov($p; $lane) | .quotaSemantics.effectiveAvailability // []);
  def bare($m): ($m | split("/") | last);
  def provider_of($c): ($c.provider // $pmap[$c.harness] // null);
  def lane_of($c): quota_lane($c.harness; $c.model);
  def measured($p; $lane):
    (prov($p; $lane) != null and (["known", "partial"] | index(prov($p; $lane).quotaSemantics.status)) != null);
  def applicable($p; $lane; $m):
    (bare($m)) as $bare |
    [rows($p; $lane)[] | select(
      .scope == "all_models" or .scope == "all_products" or
      ($m != "" and (.scope == ("model:" + $bare) or .scope == ("product:" + $bare)))
    )];
  def floor_state($f; $p; $lane):
    if $f == null then "none"
    elif prov($p; $lane) == null or (measured($p; $lane) | not) then "unknown"
    else [rows($p; $lane)[] | select(.scope == $f.scope)] as $matches
      | if ($matches | length) == 0 or any($matches[]; .status != "known") then "unknown"
        elif any($matches[]; .effectivePercentRemaining < $f.min_percent) then "below"
        else "ok"
        end
    end;
  def evidence($rows):
    $rows | map({scope, status, pct: (.effectivePercentRemaining // null), runway: (.runway.status // null), spendPriority: (.selection.spendPriority // null)});
  def evaluate($c):
    (provider_of($c)) as $p | (lane_of($c)) as $lane |
    if $p == null then {profile: $c, eligible: false, reason: "no provider family for harness \($c.harness); declare provider on the profile"}
    elif prov($p; $lane) == null then
      {profile: $c, provider: $p, eligible: true, unranked: true,
       reason: (if any($q.providers[]; .provider == $p)
                then "provider \($p) has no quota row for account \(if $lane == "" then "default" else $lane end)"
                else "provider \($p) not in the quota snapshot" end)}
    else
      (applicable($p; $lane; ($c.model // ""))) as $rows |
      (evidence($rows)) as $bounds |
      (floor_state($c.floor; $p; $lane)) as $profile_floor_state |
      if any($rows[]; (.runway.status // "") == "exhausted_now") then
        ($rows | map(select((.runway.status // "") == "exhausted_now")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: ($bad.effectivePercentRemaining // null), runway: $bad.runway.status, eligible: false, reason: "runway exhausted_now at \($bad.scope)"}
      elif any($rows[]; .status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0) then
        ($rows | map(select(.status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0)) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: false, reason: "0% remaining at \($bad.scope)"}
      elif $profile_floor_state == "below" then
        ([rows($p; $lane)[] | select(
          .scope == $c.floor.scope and
          .effectivePercentRemaining < $c.floor.min_percent
        )] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, scope: ($floor_row.scope // $c.floor.scope), pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: false, reason: "profile floor \($c.floor.scope) below \($c.floor.min_percent)%"}
      elif (measured($p; $lane) | not) then
        ($rows | first) as $row |
        {profile: $c, provider: $p, bounds: $bounds, scope: ($row.scope // null), pct: ($row.effectivePercentRemaining // null), runway: ($row.runway.status // null), eligible: true, unranked: true, unknown: true, reason: "provider \($p) unmeasured (\(prov($p; $lane).quotaSemantics.status))"}
      elif ($rows | length) == 0 then
        {profile: $c, provider: $p, bounds: $bounds, eligible: true, unranked: true, unknown: true, reason: "no applicable quota row for provider \($p)"}
      elif $profile_floor_state == "unknown" then
        ([rows($p; $lane)[] | select(.scope == $c.floor.scope)] | first) as $floor_row |
        {profile: $c, provider: $p, bounds: $bounds, scope: $c.floor.scope, pct: ($floor_row.effectivePercentRemaining // null), runway: ($floor_row.runway.status // null), eligible: true, unranked: true, unknown: true, reason: "profile floor \($c.floor.scope) is unverifiable: not rankable"}
      elif any($rows[]; .status != "known") then
        ($rows | map(select(.status != "known")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, eligible: true, unranked: true, unknown: true, reason: "quota row \($bad.scope) unknown: not rankable"}
      elif any($rows[]; (.selection.spendPriority | type) != "number") then
        ($rows | map(select((.selection.spendPriority | type) != "number")) | first) as $bad |
        {profile: $c, provider: $p, bounds: $bounds, scope: $bad.scope, pct: $bad.effectivePercentRemaining, runway: $bad.runway.status, eligible: true, unranked: true, reason: "spendPriority missing or non-numeric at \($bad.scope): not rankable"}
      else
        ($rows | min_by(.selection.spendPriority)) as $limiting |
        {profile: $c, provider: $p, bounds: $bounds, scope: $limiting.scope, pct: $limiting.effectivePercentRemaining,
         spendPriority: $limiting.selection.spendPriority, runway: $limiting.runway.status, eligible: true, reason: "ok"}
      end
      | . + {account: (prov($p; $lane).accountKey // ""), charged: ([$rows[].firstmateCharged // 0] | max // 0),
             feed: (prov($p; $lane).firstmateFeed // null)}
    end | . + {cache: (if $p == null then null else (prov($p; $lane).firstmateCache // null) end)};
'

# One brief's resolution across the pool, charged with every earlier
# placement still inside the charge window, whether from this call or an
# earlier one, except an earlier placement of this same task. Prints
# {result, ledger}.
# shellcheck disable=SC2016  # jq program text, not shell expansion
POOL_JQ='
  ($answer[0]) as $ans | ($rules[0]) as $cfg | ($homes[0]) as $homes | ($ledger[0]) as $ledger |
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def selection_mode($cfg; $rule): ($rule.select // $cfg.select // "quota-balanced");
  # quota-balanced near-tie band in spendPriority units; docs/configuration.md
  # "Candidate selection policy" owns the value and its rationale.
  def near_tie_band: 0.05;
  # The estimated draw one placed task takes from its account; the same
  # section owns these values and their rationale.
  def draw_percent: 5;
  def draw_priority: 0.1;
  def round4: (. * 10000 | round) / 10000;
  def rule_at($c):
    if ($c | test("^rule_[1-9][0-9]*$")) then
      ($c | ltrimstr("rule_") | tonumber) as $n |
      if $n <= (($cfg.rules // []) | length) then $cfg.rules[$n - 1] else null end
    else null end;
  # Recent placements on a machine, other than this task'"'"'s own. A Claude
  # placement already counted as that machine'"'"'s live crew takes no second slot.
  def recent($home): [$ledger.entries[] | select(.home == $home and .key != $key)];
  def recent_account($home; $provider; $account):
    [recent($home)[] | select(.provider == $provider and .account == $account)];
  def charges($home; $provider; $account; $scope):
    [recent_account($home; $provider; $account)[] | select(
      ((.scopes | type) == "array") and (.scopes | index($scope)) != null
    )] | length;
  def slots($home; $counted):
    [recent($home)[] | select(.claude) | .key as $k | select(($counted // []) | index($k) | not)] | length;
  def charged($snap; $home):
    $snap | .providers |= map(. as $row |
      if ((.quotaSemantics.effectiveAvailability | type) != "array") then .
      else .quotaSemantics.effectiveAvailability |= map(
        charges($home; $row.provider; ($row.accountKey // ""); .scope) as $n |
        .firstmateCharged = $n |
        if $n == 0 then . else
          (if (.effectivePercentRemaining | type) == "number"
           then .effectivePercentRemaining = ((.effectivePercentRemaining - draw_percent * $n) | round4) else . end)
          | (if (.selection.spendPriority | type) == "number"
             then .selection.spendPriority = ((.selection.spendPriority - draw_priority * $n) | round4) else . end)
        end)
      end);
  def where($id): if $id == "local" then "this machine" else $id end;
  # The Claude crew guard for one machine: the same cap and session floor
  # spawn admission enforces there, charged with this call'"'"'s placements.
  # An unranked candidate keeps its quota uncertainty; it is never selected.
  def guard($c; $h):
    if $fmap[$c.profile.harness] != "claude" or ($c.eligible | not) or ($c.unranked // false) then $c
    else ($h.admission) as $a | slots($h.id; $a.counted) as $s |
      (if $a == null then "Claude crew guard unverifiable on \(where($h.id)): its quota snapshot carries no crew evidence"
       elif $a.unknown then "Claude crew guard unverifiable on \(where($h.id)): \($a.unknown)"
       elif ($a.count + $s) >= $a.cap then
         "Claude crew at its limit on \(where($h.id)): \($a.count + $s) of \($a.cap)"
         + (if ($a.counted | length) > 0 then " (live: \($a.counted | join(", ")))" else "" end)
         + (if $s > 0 then " (+\($s) recent placement(s))" else "" end)
       elif $a.session.unknown then "Claude session floor unverifiable on \(where($h.id)): \($a.session.unknown)"
       elif ($a.session.pct - draw_percent * $s) < $a.floor then
         "Claude session \(($a.session.pct - draw_percent * $s) | round4)% below the \($a.floor)% floor on \(where($h.id))"
       else null end) as $refusal |
      if $refusal == null then $c
      else $c + {eligible: false, unranked: false, reason: $refusal} end
    end;
  def worker_load($c; $h):
    recent_account($h.id; $c.provider; $c.account) as $recent |
    if $fmap[$c.profile.harness] == "claude" and $h.admission != null and ($h.admission.unknown | not) then
      $h.admission.count
      + ([$recent[] | .key as $k | select(($h.admission.counted // []) | index($k) | not)] | length)
    else $recent | length
    end;
  def rank_key: [.order, -(.spendPriority), .home, .profile.harness, (.profile.model // ""), (.profile.effort // "")];
  def task_hash: reduce ($key | explode[]) as $cp (5381; ((. * 33 + $cp) % 2147483647));
  def exact_tie_pick($xs):
    if ([$xs[].home] | unique | length) < 2 then {best: $xs[0]}
    else
      ($xs | min_by(.workers).workers) as $fewest |
      ([$xs[] | select(.workers == $fewest)] | sort_by(.home, .profile.harness, (.profile.model // ""), (.profile.effort // ""))) as $lightest |
      if ($lightest | length) == 1 then
        {best: $lightest[0], exact_tie: {candidates: $xs, winner: $lightest[0], rule: "fewer live workers"}}
      else
        task_hash as $hash | ($hash % ($lightest | length)) as $index |
        {best: $lightest[$index], exact_tie: {candidates: $xs, winner: $lightest[$index], rule: "stable task-key hash", hash: $hash}}
      end
    end;
  def pool_pick($elig; $mode):
    if $mode == "candidate-order" then
      ($elig | sort_by(rank_key)) as $o |
      ([$o | to_entries[] | select(.value.runway == "through_reset") | .key] | first) as $safe |
      ([$o | to_entries[] | select(
        .value.runway != "projected_exhaustion" or $safe == null or .key >= $safe
      )]) as $viable |
      ($viable[0]) as $first |
      ([$viable[].value | select(
        .order == $first.value.order and .spendPriority == $first.value.spendPriority and
        ($safe == null or .runway != "projected_exhaustion")
      )]) as $exact |
      exact_tie_pick($exact) as $tie |
      $tie + {passed_over: $o[:$first.key], passed_kind: "later"}
    else
      (any($elig[]; .runway == "through_reset")) as $safe |
      (if $safe then [$elig[] | select(.runway != "projected_exhaustion")] else $elig end) as $kept |
      ($kept | max_by(.spendPriority).spendPriority) as $top |
      ([$kept[] | select($top - .spendPriority <= near_tie_band + 1e-9)] | sort_by(rank_key)) as $near |
      ([$near[] | select(.order == $near[0].order and .spendPriority == $near[0].spendPriority)]) as $exact |
      exact_tie_pick($exact) as $tie |
      $tie + {
        near_tie: (if ([$near[].order] | unique | length) > 1 then $near else null end),
        passed_over: (if $safe then [$elig[] | select(.runway == "projected_exhaustion" and .spendPriority >= $top - near_tie_band - 1e-9)] | sort_by(rank_key) else [] end),
        passed_kind: "pool"
      }
    end;
  ($ans.resolved_rule) as $choice | (rule_at($choice)) as $rule |
  (selection_mode($cfg; $rule)) as $mode |
  ($homes | length > 1) as $pooled |
  [$homes | to_entries[] | .key as $hi | .value as $h |
    if ($h.eligible | not) or $h.snapshot == null then $h + {index: $hi, candidates: [], unavailable: ($h.snapshot == null), slots: slots($h.id; $h.admission.counted)}
    else charged($h.snapshot; $h.id) as $q |
'"$CANDIDATE_JQ"'
      (if $rule == null then {source: "default", use: profiles($cfg.default // null), note: "no rule matched", mode: $mode, rank: 1}
       else floor_state($rule.floor; $rule.floor.provider; "") as $state |
         if $state == "unknown" then {unverifiable: "rule \($choice) floor \($rule.floor.provider)/\($rule.floor.scope) is unverifiable"}
         elif $state == "below" then {source: "default", use: profiles($cfg.default // null), note: "rule \($choice) floor \($rule.floor.scope) below \($rule.floor.min_percent)%: fall through to default", mode: $mode, rank: 1}
         else {source: $choice, use: profiles($rule.use), note: "rule matched", mode: $mode, rank: 0}
         end
       end) as $sel |
      $h + {index: $hi, sel: $sel, slots: slots($h.id; $h.admission.counted),
        candidates: [($sel.use // []) | to_entries[] | . as $e |
          (evaluate($e.value) + {home: $h.id, order: [$sel.rank, $e.key]}) | guard(.; $h) |
          . + {workers: worker_load(.; $h)}]}
    end] as $evald |
  ([$evald[] | select(.sel)]) as $usable |
  ([$evald[].candidates[]]) as $cands |
  ([$usable[] | select(.sel.use)] | first | .sel) as $lead |
  ({model: $ans.model, latency_ms: $ans.latency_ms, tokens: $ans.tokens, rule: $ans.rule,
    rule_when: $ans.rule_when, confidence: $ans.confidence, probabilities: $ans.probabilities}
   + (if $ans.fallback then {fallback: $ans.fallback} else {} end)
   + {pooled: $pooled, homes: [$evald[] | del(.snapshot, .candidates)]}) as $ev |
  (if $ans.kind == "ambiguous" then
     $ev + {status: "ambiguous", reason: $ans.reason, candidates: $cands}
   elif $ans.kind == "approval" then
     $ev + {status: "escalate", reason: $ans.reason, candidates: $cands}
   elif ($usable | length) == 0 then
     $ev + {status: "escalate", reason: "no machine in the pool can take this project now", candidates: []}
   elif ([$usable[] | select(.sel.use)] | length) == 0 then
     $ev + {status: "escalate", reason: $usable[0].sel.unverifiable, candidates: []}
   elif ([$usable[] | select(.sel.use) | .sel.use[]] | length) == 0 then
     $ev + {status: "escalate", reason: "no profiles configured for \($lead.source)", note: $lead.note, candidates: []}
   else
     ($ev + {selection: $mode}) as $ev |
     ([$cands[] | select(.eligible and ((.unranked // false) | not))]) as $elig |
     ([$cands[] | select(.eligible and .unranked)]) as $unranked |
     if ($elig | length) == 0 then $ev + {status: "escalate", reason: "no rankable eligible candidate", candidates: $cands}
     else
       pool_pick($elig; $mode) as $pick |
       ($pick.best) as $best |
       ([$usable[] | select(.id == $best.home) | .sel] | first) as $chosen_sel |
       $ev + {status: "clear", candidates: $cands, chosen: $best,
              passed_over: ($pick.passed_over // []), passed_kind: $pick.passed_kind}
       + (if $chosen_sel.note then {note: $chosen_sel.note} else {} end)
       + (if $pick.exact_tie then {exact_tie: $pick.exact_tie} else {} end)
       + (if $pick.near_tie then {near_tie: $pick.near_tie, near_tie_band: near_tie_band} else {} end)
       + (if ($unranked | length) > 0 then
            {unranked_note: "\($unranked | length) eligible candidate(s) unranked (\([$unranked[].provider] | unique | join(", ")))"}
          else {} end)
       + (if $pooled then
            {placement: {home: $best.home,
              reason: ((if $best.home == "local" then "local" else $best.home end) + " "
                + "\($best.profile.harness):\($best.profile.model // "-") "
                + (if $pick.exact_tie then "wins an exact cross-home tie at spendPriority \($best.spendPriority) by \($pick.exact_tie.rule)"
                   elif $mode == "candidate-order" then "is the first passing candidate in configured order across the pool"
                   elif $pick.near_tie then "wins a near-tie at spendPriority \($best.spendPriority) by configured order"
                   else "has the pool'"'"'s highest spendPriority \($best.spendPriority)" end)
                + (if ($pick.passed_over | length) > 0 then "; \($pick.passed_over | length) candidate(s) projected to run out before reset passed over" else "" end))}}
          else {} end)
     end
   end) as $result |
  {result: $result,
   ledger: (if $result.status == "clear" then
     ($result.chosen) as $c |
     $ledger | .entries = ([.entries[] | select(.key != $key)]
       + [{at: $now, key: $key, home: $c.home, provider: $c.provider, account: $c.account,
           model: ($c.profile.model // ""), scopes: ([$c.bounds[]?.scope] | unique),
           claude: ($fmap[$c.profile.harness] == "claude")}])
   else $ledger end)}
'
# Placements are charged for CHARGE_WINDOW seconds, the longest a reused quota
# reading can be, so separate calls in a burst spread like one batch. A task is
# keyed by its data/<id>/ directory when its brief is data/<id>/brief.md, else
# by the brief path, so resolving the same task again replaces its charge.
CHARGE_WINDOW=900
LEDGER_FILE="$STATE/dispatch-charges.jsonl"
NOW=$(date +%s)
if [ -f "$LEDGER_FILE" ] && [ ! -L "$LEDGER_FILE" ]; then
  jq -cs --argjson now "$NOW" --argjson window "$CHARGE_WINDOW" '
    {entries: ([.[] | select(type == "object" and (.at | type) == "number" and (.key | type) == "string"
       and (.home | type) == "string" and $now - .at >= 0 and $now - .at < $window)]
     | group_by(.key) | map(max_by(.at)))}' "$LEDGER_FILE" > "$WORK/ledger.json" 2>/dev/null \
    || printf '%s\n' '{"entries":[]}' > "$WORK/ledger.json"
else
  printf '%s\n' '{"entries":[]}' > "$WORK/ledger.json"
fi
cp "$WORK/ledger.json" "$WORK/ledger.start"

brief_key() { # <index>
  local brief=${BRIEFS[$1]} dir
  dir=$(cd "$(dirname "$brief")" 2>/dev/null && pwd -P) || dir=$(dirname "$brief")
  if [ "$(basename "$brief")" = brief.md ]; then
    basename "$dir"
  else
    printf '%s/%s\n' "$dir" "$(basename "$brief")"
  fi
}

for i in "${!BRIEFS[@]}"; do
  [ ! -e "$WORK/result.$i.json" ] || continue
  homes_for "$i"
  if [ -n "$quota_failure" ] && ! jq -e 'any(.[]; .snapshot != null)' "$WORK/homes.$i.json" >/dev/null 2>&1; then
    brief_error "$i" "$quota_failure"
    continue
  fi
  if jq -n --argjson pmap "$PMAP" --argjson fmap "$FMAP" --arg key "$(brief_key "$i")" --argjson now "$NOW" \
      --slurpfile answer "$WORK/answer.$i.json" --slurpfile rules "$RULES" \
      --slurpfile homes "$WORK/homes.$i.json" --slurpfile ledger "$WORK/ledger.json" \
      "$FM_QUOTA_ROW_JQ$POOL_JQ" > "$WORK/pool.$i.json" 2>/dev/null; then
    jq -c .result "$WORK/pool.$i.json" > "$WORK/result.$i.json"
    jq -c .ledger "$WORK/pool.$i.json" > "$WORK/ledger.next" && mv "$WORK/ledger.next" "$WORK/ledger.json"
  else
    brief_error "$i" "resolution failed"
  fi
done

# Persist the charge window: the recent placements read above plus this
# call's. A concurrent call can lose one of these estimates, never a task.
if ! cmp -s "$WORK/ledger.start" "$WORK/ledger.json"; then
  if mkdir -p "$STATE" 2>/dev/null && tmp=$(mktemp "$STATE/.dispatch-charges.XXXXXX" 2>/dev/null); then
    if ! { jq -c '.entries[]' "$WORK/ledger.json" > "$tmp" && mv -f "$tmp" "$LEDGER_FILE"; }; then
      rm -f "$tmp"
    fi
  fi
fi

# ---- output -------------------------------------------------------------------
# shellcheck disable=SC2016  # jq program text, not shell expansion
RENDER_JQ='
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($value): ($value // "-") | flat;
  def shell_arg: flat | @sh;
  def at($c): if ($c.home // "local") == "local" then "" else "home=\($c.home | flat) " end;
  def hm($c): "\(at($c))\($c.profile.harness | flat):\(show($c.profile.model))";
  "dispatch-resolve:",
  (if $brief != "" then "  brief: \($brief | flat)" else empty end),
  (if $project != "" then "  project: \($project | flat)" else empty end),
  "  status: \(.status | flat)",
  (if .status == "error" or .status == "off" then "  reason: \(.reason | flat)"
   else
    "  model: \(show(.model))   latency_ms: \(show(.latency_ms))   tokens: \(show(.tokens.input_tokens))/\(show(.tokens.output_tokens))",
    "  rule: \(.rule | flat) (\(.rule_when | flat))   confidence: \(.confidence | flat)",
    "  probabilities: \([.probabilities | to_entries[] | "\(.key | flat)=\(.value | flat)"] | join(" "))",
    (if .fallback then "  fallback: \(.fallback | flat)" else empty end),
    (if .reason then "  reason: \(.reason | flat)" else empty end),
    (if .selection then "  selection: \(.selection | flat)" else empty end),
    (if .note then "  note: \(.note | flat)" else empty end),
    (if .unranked_note then "  note: \(.unranked_note | flat)" else empty end),
    (.candidates[]? | "  candidate: \(hm(.))"
        + (if .provider then "  provider=\(.provider | flat)" else "" end)
        + (if .scope then "  scope=\(.scope | flat)  remaining=\(show(.pct))%  spendPriority=\(show(.spendPriority))  runway=\(show(.runway))" else "" end)
        + (if (.bounds // [] | length) > 1 then "  bounds=" + ([.bounds[] | "\(.scope | flat):\(show(.pct))%/\((.runway // .status) | flat)"] | join(",")) else "" end)
        + (if .cache then "  cached=\(.cache.ageSeconds)s old" else "" end)
        + (if .feed then "  feed=\(.feed.ageSeconds)s old" else "" end)
        + (if (.charged // 0) > 0 then "  charged=\(.charged) recent placement(s)" else "" end)
        + "  -> " + (if .unranked then "eligible, unranked: \(.reason | flat): disclosed uncertainty"
                     elif .eligible and ((.runway // "unknown") == "unknown") then "eligible, runway unknown: disclosed uncertainty"
                     elif .eligible then "eligible" else "not eligible: \(.reason | flat)" end)),
    (.passed_kind as $kind | .passed_over[]? | "  passed over: \(hm(.)): projected to run out before reset; "
        + (if $kind == "pool" then "another eligible candidate in the pool has runway through_reset"
           else "later eligible candidate has runway through_reset" end)),
    (if .near_tie then "  near-tie broken by configured order: "
        + ([.near_tie[] | "\(hm(.))=\(show(.spendPriority))"] | join(", "))
        + " (within \(.near_tie_band | flat))" else empty end),
    (if .exact_tie then "  exact cross-home tie: "
        + ([.exact_tie.candidates[] | "\(hm(.))=\(show(.spendPriority)) workers=\(.workers)"] | join(", "))
        + " -> \(hm(.exact_tie.winner)) by \(.exact_tie.rule | flat)"
        + (if .exact_tie.hash then " \(.exact_tie.hash)" else "" end)
      else empty end),
    (if .chosen then "  profile: --harness \(.chosen.profile.harness | shell_arg)"
        + (if .chosen.profile.model then " --model \(.chosen.profile.model | shell_arg)" else "" end)
        + (if .chosen.profile.effort then " --effort \(.chosen.profile.effort | shell_arg)" else "" end)
        + (if .chosen.profile.harness == "claude" and .chosen.profile.floor then
             " --profile-floor-scope \(.chosen.profile.floor.scope | shell_arg) --profile-floor-min-percent \(.chosen.profile.floor.min_percent | shell_arg)"
           else "" end) else empty end),
    (if .placement then
       "  placement: \(if .placement.home == "local" then "local" else "secondmate \(.placement.home | flat)" end) (\(.placement.reason | flat))"
     else empty end),
    (if .pooled then
       (.homes[] | "  home: \(.id | flat)"
         + (if .eligible == false then "  not eligible: \(.reason | flat)"
            elif .unavailable then "  unknown: \(.reason | flat): disclosed uncertainty"
            elif .sel.unverifiable then "  unknown: \(.sel.unverifiable | flat) there: disclosed uncertainty"
            else
              (if .admission == null then "  claude-crew=unknown (its snapshot carries no crew evidence)"
               elif .admission.unknown then "  claude-crew=unknown (\(.admission.unknown | flat))"
               else "  claude-crew=\(.admission.count)/\(.admission.cap)"
                 + (if (.slots // 0) > 0 then " +\(.slots) recent placement(s)" else "" end)
                 + (if .admission.session.pct != null then "  session=\(.admission.session.pct)%" else "  session=unknown" end)
               end)
              + (if .cache_age != null then "  cached=\(.cache_age)s old" else "" end)
              + (if .sel.note and .sel.source == "default" and .sel.note != "no rule matched" then "  note=\(.sel.note | flat)" else "" end)
            end))
     else empty end)
   end)
'

render() { # <index>
  local brief='' project=''
  if [ "$BRIEF_COUNT" -gt 1 ]; then
    brief=${BRIEFS[$1]}
    project=${PROJECTS[$1]}
  fi
  jq -r --arg brief "$brief" --arg project "$project" "$RENDER_JQ" "$WORK/result.$1.json"
}

for i in "${!BRIEFS[@]}"; do
  if jq -e '.status == "off"' "$WORK/result.$i.json" >/dev/null 2>&1 && [ "$BRIEF_COUNT" -eq 1 ]; then
    continue
  fi
  if ! TEXT=$(render "$i"); then
    echo "dispatch-resolve: error (output rendering failed)" >&2
    TEXT=$(printf 'dispatch-resolve:\n  status: error\n  reason: output rendering failed')
  fi
  printf '%s\n' "$TEXT"
done

# A batch closes with the split of its placements by machine and provider.
if [ "$BRIEF_COUNT" -gt 1 ]; then
  for i in "${!BRIEFS[@]}"; do cat "$WORK/result.$i.json"; done | jq -rs '
    def tally(f): group_by(f) | map("\(.[0] | f)=\(length)") | join(" ");
    [.[] | select(.status == "clear") | .chosen] as $placed |
    "dispatch-batch:",
    "  briefs: \(length)   clear: \($placed | length)   other: \(length - ($placed | length))",
    (if ($placed | length) > 0 then
       "  machine: \($placed | tally(.home))",
       "  provider: \($placed | tally(.provider))",
       "  profile: \($placed | tally("\(.home):\(.profile.harness):\(.profile.model // "-")"))"
     else empty end)'
fi
exit 0
