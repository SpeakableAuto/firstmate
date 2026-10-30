#!/usr/bin/env bash
# Home-level CLEAR-but-unmerged monitoring, using the existing registered check cadence.
# Usage: fm-clear-unmerged-check.sh [check|arm|disarm|--help]
# arm installs a private, hash-bound state/clear-unmerged.check.sh shim for
# fm-watch.sh's FM_CHECK_INTERVAL loop; no daemon or default activation is added.
# disarm unregisters the shim but preserves the per-PR/head notification history.
# check prints one actionable line (or nothing); fm-watch.sh makes it a check wake.
# The Python companion owns discovery, clock, exclusions, bounds and state format.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

case "${1:-check}" in
  -h|--help)
    sed -n '2,9s/^# //p' "$0"
    python3 "$SCRIPT_DIR/fm-clear-unmerged-check.py" --help
    ;;
  check) exec python3 "$SCRIPT_DIR/fm-clear-unmerged-check.py" ;;
  disarm) exec "$SCRIPT_DIR/fm-check-unregister.sh" clear-unmerged ;;
  arm)
    mkdir -p "$STATE"
    [ ! -L "$STATE" ] || { echo 'refused: state is a symlink' >&2; exit 1; }
    FM_HOME=$(cd "$FM_HOME" && pwd -P)
    export FM_HOME
    device=$(fm_pr_file_device "$STATE")
    shim="$STATE/clear-unmerged.check.sh"
    fm_pr_regular_destination_on_device_or_absent "$shim" "$device" || exit 1
    fm_pr_regular_destination_on_device_or_absent "$STATE/clear-unmerged.check-trust" "$device" || exit 1
    tmp=$(umask 077; mktemp "$STATE/.clear-unmerged-shim.XXXXXX")
    trap 'rm -f -- "$tmp"' EXIT
    {
      printf '#!/usr/bin/env bash\nexport FM_HOME=%q\n' "$FM_HOME"
      printf 'exec %q check\n' "$SCRIPT_DIR/fm-clear-unmerged-check.sh"
    } > "$tmp"
    chmod 700 "$tmp"
    mv -f -- "$tmp" "$shim"
    "$SCRIPT_DIR/fm-check-register.sh" clear-unmerged >/dev/null
    printf 'armed: state/clear-unmerged.check.sh\n'
    ;;
  *) echo 'error: unknown action; use check, arm, disarm or --help' >&2; exit 2 ;;
esac
