# shellcheck shell=bash
# Shared live-worker evidence and launch admission for configured quota pacing.
# docs/configuration.md "Quota pacing" owns the configuration and behavior.

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-control-lib.sh"

fm_quota_pacing_agent_state() { # <backend> <target>
  local backend=$1 target=$2 verdict
  [ -n "$target" ] || { printf 'unreadable'; return 0; }
  verdict=$(fm_backend_agent_state "$backend" "$target")
  if [ "$backend:$verdict" = herdr:unreadable ] \
     && fm_backend_herdr_parse_target "$target" \
     && [ "$(fm_backend_herdr_pane_process_state "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")" = shell ]; then
    verdict=dead
  fi
  printf '%s' "$verdict"
}

fm_quota_pacing_meta_identity() { # <snapshot-file> <meta>
  local snapshot=$1 meta=$2 harness family model provider lane account
  harness=$(fm_meta_get "$meta" harness)
  family=$(fm_control_harness_family "$harness" 2>/dev/null) || family=$harness
  model=$(fm_meta_get "$meta" model)
  provider=$(fm_quota_provider_for_harness "$family" "$model" 2>/dev/null) || return 1
  lane=$(jq -rn --arg h "$family" --arg m "$model" "$FM_QUOTA_ROW_JQ"'quota_lane($h; $m)') || return 1
  account=$(jq -r --arg provider "$provider" --arg lane "$lane" "$FM_QUOTA_ROW_JQ"'
    quota_row(.; $provider; $lane) | if . == null then "unknown" else (.accountKey // "default") end
  ' "$snapshot" 2>/dev/null) || return 1
  printf '%s\t%s\n' "$provider" "$account"
}

fm_quota_pacing_count() { # <state> <snapshot-file> <exclude-id> <provider> <account-key>
  local state=$1 snapshot=$2 exclude=$3 provider=$4 account=$5
  local meta identity worker_provider worker_account backend target verdict absence gen started now task count=0 counted=''
  now=$(date +%s)
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$meta" != "$state/$exclude.meta" ] || continue
    [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
    identity=$(fm_quota_pacing_meta_identity "$snapshot" "$meta" 2>/dev/null) || continue
    worker_provider=${identity%%$'\t'*}
    worker_account=${identity#*$'\t'}
    [ "$worker_provider" = "$provider" ] || continue
    [ "$worker_account" = unknown ] || [ "$worker_account" = "$account" ] || continue
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    if fm_backend_source "$backend"; then
      verdict=$(fm_quota_pacing_agent_state "$backend" "$target")
    else
      verdict=unverified
    fi
    if [ "$verdict" = missing ]; then
      absence=$(fm_control_endpoint_absence_verdict "$backend" "$target")
      case "${absence%%$'\t'*}" in
        gone|dead) verdict=dead ;;
        *) verdict=unreadable ;;
      esac
    fi
    if [ "$verdict" = dead ]; then
      gen=$(fm_meta_get "$meta" spawn_gen)
      started=${gen#s}; started=${started%%.*}
      case "$started" in ''|*[!0-9]*) continue ;; esac
      [ "$((now - started))" -lt 60 ] || continue
    fi
    count=$((count + 1))
    task=${meta##*/}; task=${task%.meta}
    counted="${counted:+$counted, }$task"
  done
  FM_QUOTA_PACING_COUNT=$count
  FM_QUOTA_PACING_COUNTED=$counted
}

fm_quota_pacing_state() { # <config-file> <state> <snapshot-file> [epoch-seconds] [exclude-id]
  local config=$1 state=$2 snapshot=$3 clock=${4:-} exclude=${5:-} calculated provider account
  local script_dir out
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if [ -n "$clock" ]; then
    calculated=$(node "$script_dir/fm-quota-pacing.mjs" "$config" "$snapshot" "$clock") || return 1
  else
    calculated=$(node "$script_dir/fm-quota-pacing.mjs" "$config" "$snapshot") || return 1
  fi
  out=$calculated
  while IFS=$'\t' read -r provider account; do
    [ -n "$provider" ] || continue
    fm_quota_pacing_count "$state" "$snapshot" "$exclude" "$provider" "$account"
    out=$(printf '%s\n' "$out" | jq -c --arg provider "$provider" --arg account "$account" \
      --argjson count "$FM_QUOTA_PACING_COUNT" --arg counted "$FM_QUOTA_PACING_COUNTED" '
      .accounts |= map(if .provider == $provider and .accountKey == $account then
        . + {liveCount:$count, countedTaskIds:(if $counted == "" then [] else ($counted | split(", ")) end)}
      else . end)') || return 1
  done < <(printf '%s\n' "$calculated" | jq -r '.accounts | map([.provider,.accountKey]) | unique[] | @tsv')
  printf '%s\n' "$out"
}

fm_quota_pacing_config_applies() { # <config-dir> <harness> <model>
  local config=$1 harness=$2 model=$3 family provider lane applies script_dir config_file
  config_file=$config/crew-dispatch.json
  if [ ! -e "$config_file" ] && [ ! -L "$config_file" ]; then
    return 1
  fi
  if [ ! -f "$config_file" ] || [ ! -r "$config_file" ]; then
    echo "error: invalid quota pacing settings in $config_file" >&2
    return 2
  fi
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if ! printf '%s\n' '{"schemaVersion":5,"providers":[]}' \
      | node "$script_dir/fm-quota-pacing.mjs" "$config_file" - >/dev/null 2>&1; then
    echo "error: invalid quota pacing settings in $config_file" >&2
    return 2
  fi
  family=$(fm_control_harness_family "$harness" 2>/dev/null) || family=$harness
  provider=$(fm_quota_provider_for_harness "$family" "$model" 2>/dev/null) || return 1
  lane=$(jq -rn --arg h "$family" --arg m "$model" "$FM_QUOTA_ROW_JQ"'quota_lane($h; $m)') || return 2
  applies=$(jq -r --arg provider "$provider" --arg lane "$lane" '
    [.quota_pacing.accounts[]? | select(.provider == $provider)] as $accounts |
    if $lane != "" and any($accounts[]; (.account_key // "default") == $lane) then $lane
    elif any($accounts[]; (.account_key // "default") == "default") then "default"
    else "" end
  ' "$config_file") || return 2
  [ -n "$applies" ] || return 1
  FM_QUOTA_PACING_PROVIDER=$provider
  FM_QUOTA_PACING_ACCOUNT=$applies
}

fm_quota_pacing_admission_check() { # <config-dir> <state> <id> <harness> <model>
  local config=$1 state=$2 id=$3 harness=$4 model=$5 provider account snapshot merged pacing bare applicable cap count counted status row
  if fm_quota_pacing_config_applies "$config" "$harness" "$model"; then
    status=0
  else
    status=$?
  fi
  case "$status" in
    0) ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
  provider=$FM_QUOTA_PACING_PROVIDER
  account=$FM_QUOTA_PACING_ACCOUNT
  snapshot=$(mktemp) || return 1
  merged=$(mktemp) || { rm -f "$snapshot"; return 1; }
  if ! fm_quota_read_json 15 quota-axi --json > "$snapshot" 2>/dev/null \
     || ! fm_quota_json_valid < "$snapshot" \
     || ! fm_quota_feed_merge "$config" "$snapshot" > "$merged"; then
    rm -f "$snapshot" "$merged"
    echo "error: quota pacing admission refused for provider $provider because quota evidence is unavailable" >&2
    return 1
  fi
  row=$(jq -c --arg provider "$provider" --arg account "$account" '
    if .schemaVersion == 6 then
      [.providers[] | select(.provider == $provider and .accountKey == $account)] | first
    elif $account == "default" then
      [.providers[] | select(.provider == $provider)] | first
    else null end
  ' "$merged" 2>/dev/null) || row=null
  if [ "$row" = null ]; then
    rm -f "$snapshot" "$merged"
    echo "error: quota pacing admission refused for provider $provider account $account because the configured account cannot be measured" >&2
    return 1
  fi
  pacing=$(fm_quota_pacing_state "$config/crew-dispatch.json" "$state" "$merged" '' "$id") || {
    rm -f "$snapshot" "$merged"
    echo "error: quota pacing admission refused for provider $provider because pacing evidence is invalid" >&2
    return 1
  }
  bare=${model##*/}
  applicable=$(printf '%s\n' "$pacing" | jq -c --arg provider "$provider" --arg account "$account" --arg bare "$bare" '
    [.accounts[] | select(.provider == $provider and .accountKey == $account and
      (.scope == "all_models" or .scope == "all_products" or
       ($bare != "" and $bare != "default" and (.scope == ("model:" + $bare) or .scope == ("product:" + $bare)))))]
  ') || applicable='[]'
  rm -f "$snapshot" "$merged"
  [ "$(printf '%s\n' "$applicable" | jq 'length')" -gt 0 ] || return 0
  if printf '%s\n' "$applicable" | jq -e 'any(.[]; .allowedConcurrency == null)' >/dev/null; then
    echo "error: quota pacing admission refused for provider $provider account $account because pacing evidence is incomplete" >&2
    return 1
  fi
  cap=$(printf '%s\n' "$applicable" | jq '[.[].allowedConcurrency] | min')
  count=$(printf '%s\n' "$applicable" | jq '.[0].liveCount')
  counted=$(printf '%s\n' "$applicable" | jq -r '.[0].countedTaskIds | join(", ")')
  if [ "$count" -ge "$cap" ]; then
    echo "error: quota pacing admission refused for provider $provider account $account: $count live or unverified crew, limit $cap; counted tasks: $counted" >&2
    return 1
  fi
}
