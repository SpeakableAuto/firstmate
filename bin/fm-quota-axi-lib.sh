# shellcheck shell=bash
# Shared quota-axi compatibility floor for the bootstrap diagnostic, the
# --json snapshot validator, and the provider-row join dispatch consumers use.
# Usage: . bin/fm-quota-axi-lib.sh
#
# FM_QUOTA_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
#
# This file is the single owner of that version number. bin/fm-bootstrap.sh
# turns a failing check into the operator-facing MISSING diagnostic, which is
# what keeps an older build from reaching a dispatch intake at all.
#
# Snapshot schemas: fm_quota_json_valid accepts quota-axi schema 5 (one row per
# provider, no accountKey) and schema 6 (every row carries accountKey, unique on
# provider + accountKey; quota-axi emits it once any provider expands to more
# than one account). Schema 5 keeps its exact pre-schema-6 rules so an older
# quota-axi keeps working unchanged. FM_QUOTA_ROW_JQ is the one join used to
# bind a candidate to its row under either schema.

FM_QUOTA_AXI_MIN=0.1.55
FM_QUOTA_PROVIDER_ID_RE='^[a-z0-9]+(-[a-z0-9]+)*\z'

# The eligibility section of .agents/skills/quota-array-dispatch/SKILL.md
# owns the account-matching contract these jq definitions implement.
# Prepend them to a consumer's program:
#   quota_lane($harness; $model)   the candidate's account key, or "" when none
#                                  is identified by the contract.
#   quota_row($snapshot; $provider; $lane)
#                                  the one provider row the candidate binds to,
#                                  or null; schema 5 ignores $lane.
# shellcheck disable=SC2016,SC2034  # jq program text, not shell expansion; read by the sourcing consumers
FM_QUOTA_ROW_JQ='
  def quota_lane($harness; $model):
    if $harness == "codex" then "codex-home"
    elif ($harness == "pi" or $harness == "pi-signed") and (($model // "") | contains("/"))
    then ($model | split("/") | first | if . == "codex-native" then "codex-home" else . end)
    else "" end;
  def quota_row($snapshot; $provider; $lane):
    ([$snapshot.providers[]? | select(.provider == $provider)]) as $rows |
    if $snapshot.schemaVersion == 6 then
      (([$rows[] | select(.accountKey == $lane)] | first) //
       ([$rows[] | select(.accountKey == "default")] | first) // null)
    else ($rows | first) // null
    end;
'

fm_quota_axi_compatible() {
  local timeout=${1:-} output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  command -v quota-axi >/dev/null 2>&1 || return 1
  if [ -n "$timeout" ]; then
    case "$timeout" in
      ''|*[!0-9]*|0) return 1 ;;
    esac
    [ "$(type -t fm_run_timed)" = function ] || return 1
    output=$(fm_run_timed "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
  else
    output=$(quota-axi --version 2>/dev/null </dev/null) || return 1
  fi
  parts=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  # The floor is compared from FM_QUOTA_AXI_MIN so bumping it needs one edit.
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_QUOTA_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

fm_quota_json_valid() {
  jq -se --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
    length == 1 and
    (.[0] | type) == "object" and
    (.[0] |
      (.providers | type) == "array" and
      (if .schemaVersion == 5 then
         (([.providers[].provider] | length) == ([.providers[].provider] | unique | length))
       elif .schemaVersion == 6 then
         all(.providers[];
           (.accountKey | type) == "string" and
           (.accountKey | length) > 0 and
           ((.accountKey | test("\\s")) | not)) and
         (([.providers[] | [.provider, .accountKey]] | length) ==
          ([.providers[] | [.provider, .accountKey]] | unique | length))
       else false
       end) and
      all(.providers[];
      (.provider | type) == "string" and
      (.provider | test($provider_re)) and
      (.quotaSemantics | type) == "object" and
      (.quotaSemantics.status as $semantics_status |
        (["known", "partial", "unknown"] | index($semantics_status)) != null and
        (.quotaSemantics.effectiveAvailability | type) == "array" and
        (if $semantics_status == "known" then
           ((.quotaSemantics.effectiveAvailability | length) > 0 and
            all(.quotaSemantics.effectiveAvailability[];
              .status == "known" or .status == "unknown"
            ))
         elif $semantics_status == "unknown" then
           all(.quotaSemantics.effectiveAvailability[]; .status == "unknown")
         else true
         end) and
        all(.quotaSemantics.effectiveAvailability[];
          type == "object" and
          (.scope | type) == "string" and
          (.scope | length) > 0 and
          ((.scope | test("^\\s|\\s$")) | not) and
          ((.status == "known" and
            (.runway.status as $runway_status |
            ((.effectivePercentRemaining | type) == "number" and
             .effectivePercentRemaining >= 0 and
             .effectivePercentRemaining <= 100 and
             (.runway | type) == "object" and
             ($runway_status | type) == "string" and
             (["through_reset", "projected_exhaustion", "exhausted_now", "unknown"] |
               index($runway_status)) != null))) or
           (.status == "unknown" and
            (has("effectivePercentRemaining") | not) and
            ((has("runway") | not) or
             ((.runway | type) == "object" and
              (.runway.status as $unknown_runway_status |
               (["unknown", "exhausted_now"] | index($unknown_runway_status)) != null)))))
        )
      )
    )
    )
  ' >/dev/null 2>&1
}

fm_quota_single_provider_table() {
  printf '%s\n' \
    'claude claude' \
    'codex codex' \
    'grok grok' \
    'kimi kimi' \
    'cursor cursor' \
    'agy agy' \
    'muse meta'
}

fm_quota_single_provider_for_harness() {
  local harness provider
  while read -r harness provider; do
    if [ "$harness" = "$1" ]; then
      printf '%s\n' "$provider"
      return 0
    fi
  done < <(fm_quota_single_provider_table)
  return 1
}

fm_quota_provider_for_harness() {
  case "$1" in
    omp)
      case "${2:-}" in
        openai-codex/*)  printf 'codex\n' ;;
        claude-bridge/*) printf 'claude\n' ;;
        *)               return 1 ;;
      esac
      ;;
    claude)       printf 'claude\n' ;;
    codex)        printf 'codex\n' ;;
    opencode)     printf 'codex\n' ;;
    pi|pi-signed) printf 'pi\n' ;;
    grok)         printf 'grok\n' ;;
    kimi)         printf 'kimi\n' ;;
    cursor)       printf 'cursor\n' ;;
    muse)         printf 'meta\n' ;;
    *)            return 1 ;;
  esac
}

# Read through quota-axi's credential-aware cache, retaining its semantics and
# account joins. Configuration and fallback policy: docs/configuration.md,
# "Quota snapshot reuse". The command prefix may include an account-scoped env.
# Usage: fm_quota_read_json <timeout-seconds> <command> [args...]
fm_quota_read_json() {
  local timeout=$1 snapshot recovered started remaining arg profile_only=0 max_age=900
  shift
  case "$timeout" in ''|0*|*[!0-9]*) echo 'error: quota read timeout must be a positive integer' >&2; return 2 ;; esac
  for arg in "$@"; do [ "$arg" != --profile-only ] || profile_only=1; done
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"
  started=$(date +%s)
  snapshot=$(fm_run_timed "$timeout" env "QUOTA_AXI_MAX_AGE=${QUOTA_AXI_MAX_AGE:-15m}" "$@") || return $?
  # Let the caller retain its own invalid-snapshot diagnostic.
  if ! printf '%s\n' "$snapshot" | fm_quota_json_valid; then
    printf '%s\n' "$snapshot"
    return 0
  fi
  remaining=$((timeout - $(date +%s) + started))
  if [ "$profile_only" -eq 0 ] && [ "$remaining" -gt 0 ] && printf '%s\n' "$snapshot" | jq -e '
    any(.providers[]; .provider == "claude" and .state.stale == true
      and .state.error == "Claude quota endpoint rate limited")' >/dev/null; then
    # Never promote raw stale windows or recompute vendor ranking ourselves.
    # quota-axi checks the credential context and returns original refreshedAt.
    recovered=$(fm_run_timed "$remaining" "$@" --provider claude --max-age "${max_age}s" --no-credential-refresh 2>/dev/null) || recovered=
    if printf '%s\n' "$recovered" | fm_quota_json_valid; then
      snapshot=$(jq -cn --argjson original "$snapshot" --argjson cached "$recovered" '
        $original | .providers |= map(. as $old |
          if .provider == "claude" and .state.stale == true
            and .state.error == "Claude quota endpoint rate limited" then
            ([$cached.providers[] | select(.provider == "claude"
              and (.accountKey // "default") == ($old.accountKey // "default")
              and .state.status == "fresh" and .state.stale == false and .state.reused == true
              and (.state.error // "") == "")] | first) as $reuse |
            if $reuse == null then . else
              $reuse | (if $old.accountKey then .accountKey = $old.accountKey else . end) |
              .firstmateCache.reason = "rate limited"
            end
          else . end)') || return 1
    fi
  fi
  # Measure against wall time, never the report generation time. A future,
  # missing, malformed, or expired timestamp cannot justify a cached admission.
  printf '%s\n' "$snapshot" | jq --argjson max_age "$max_age" '
    def age: try (
      (.state.refreshedAt | capture("^(?<whole>[^.]+)(?<fraction>\\.[0-9]+)?Z$") // error("invalid timestamp")) as $stamp |
      now - (($stamp.whole + "Z" | fromdateiso8601) + (($stamp.fraction // "0") | tonumber))
    ) catch null;
    .providers |= map(
      if .provider == "claude" and .state.reused == true then
        age as $age |
        if .state.status == "fresh" and .state.stale == false and (.state.error // "") == ""
          and $age != null and $age >= 0 and $age < $max_age then
          .firstmateCache.ageSeconds = ($age | floor)
        else
          .state.stale = true | .state.status = "stale" |
          .quotaSemantics = {status:"unknown", effectiveAvailability:[]} | del(.firstmateCache)
        end
      else . end)
  '
}

# A quota feed is a quota-axi --json snapshot file that another process on this
# machine refreshes from a session where every vendor credential store is
# readable. config/quota-feed names it on one line: an absolute path, or one
# beginning with ~/ for this machine's home directory. docs/configuration.md
# "Quota snapshot reuse" owns the contract.
# Usage: fm_quota_feed_merge <config-dir> <snapshot-file>
# Prints the snapshot with every provider row it could not measure replaced by
# the feed's measured row for the same provider and account, plus measured feed
# rows the snapshot lacks, each marked firstmateFeed.ageSeconds. An empty or
# missing snapshot file prints the feed alone. An absent, unreadable, invalid,
# or older-than-FM_QUOTA_FEED_MAX_AGE (default 900 seconds) feed leaves the
# snapshot unchanged. Returns 1 only when neither yields a valid snapshot.
fm_quota_feed_merge() {
  local config=$1 snapshot=$2 path='' age max_age=${FM_QUOTA_FEED_MAX_AGE:-900} merged
  local -a live=()
  if [ -s "$snapshot" ] && fm_quota_json_valid < "$snapshot"; then
    live=("$snapshot")
  fi
  if [ -f "$config/quota-feed" ] && [ ! -L "$config/quota-feed" ]; then
    IFS= read -r path < "$config/quota-feed" || true
  fi
  # A literal ~/ prefix in the file names $HOME.
  # shellcheck disable=SC2088
  case "$path" in
    '~/'*) path="${HOME:-}/${path#\~/}" ;;
  esac
  case "$max_age" in ''|*[!0-9]*) max_age=900 ;; esac
  if [ "${path#/}" != "$path" ] && [ -f "$path" ] && [ -r "$path" ] && fm_quota_json_valid < "$path" \
     && age=$(perl -e 'my @s = stat $ARGV[0] or exit 1; print int(time - $s[9])' "$path" 2>/dev/null) \
     && [ "$age" -ge 0 ] && [ "$age" -lt "$max_age" ]; then
    merged=$(jq -nc --slurpfile feed "$path" --slurpfile live "${live[0]:-/dev/null}" --argjson age "$age" '
      def measured: ((.quotaSemantics.status // "") == "known" or (.quotaSemantics.status // "") == "partial")
        and ((.quotaSemantics.effectiveAvailability // []) | length) > 0 and (.state.stale != true);
      ($feed[0]) as $f | ($live | length) as $has_live |
      (if $has_live == 0 then $f else $live[0] end) as $base |
      ($base.schemaVersion) as $schema |
      def key: .provider + "|" + (if $schema == 6 then (.accountKey // "default") else "" end);
      ([$f.providers[]
        | if $schema == 6 then .accountKey = (.accountKey // "default")
          elif (.accountKey // "default") == "default" then del(.accountKey)
          else empty end
        | select(measured) | . + {firstmateFeed: {ageSeconds: $age}}]) as $rows |
      if $has_live == 0 then $base | .providers = ([$rows[]] + [$base.providers[] | select(measured | not)
        | . as $p | select(all($rows[]; key != ($p | key)))])
      else $base | .providers |= (map(. as $p |
          if measured then . else (([$rows[] | select(key == ($p | key))] | first) // .) end)
        + [$rows[] | . as $r | select(all($base.providers[]; key != ($r | key)))])
      end' 2>/dev/null) || merged=
    if [ -n "$merged" ] && printf '%s\n' "$merged" | fm_quota_json_valid; then
      printf '%s\n' "$merged"
      return 0
    fi
  fi
  [ "${#live[@]}" -gt 0 ] || return 1
  cat "$snapshot"
}
