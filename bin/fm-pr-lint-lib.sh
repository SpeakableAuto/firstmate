#!/usr/bin/env bash
# Optional brief/PR lint switch. Return 0 enabled, 1 absent/off, 2 invalid.
# config/brief-pr-lint contains exactly on or off (optional trailing newline).
# No Python/forge dependency is consulted when the setting is absent or off.
fm_pr_lint_enabled() {
  local config=$1 value
  [ -e "$config/brief-pr-lint" ] || [ -L "$config/brief-pr-lint" ] || return 1
  if [ ! -f "$config/brief-pr-lint" ] || ! value=$(cat "$config/brief-pr-lint"); then
    echo 'refuse: brief-pr-lint config; fix: use a readable file containing on or off' >&2
    return 2
  fi
  case "$value" in
    on) return 0 ;;
    off) return 1 ;;
    *) echo 'refuse: brief-pr-lint config; fix: set config/brief-pr-lint to on or off' >&2; return 2 ;;
  esac
}
