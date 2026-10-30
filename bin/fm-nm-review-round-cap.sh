#!/bin/sh
# Refuse another review fix after the configured number of completed reviews.
# Exit 0 permits the response; exit 3 asks firstmate to triage it.
# This is a read-only preflight: it never submits a pipeline response.
# Invoke with the same arguments as no-mistakes before executing its binary.
# NM_REVIEW_ROUND_CAP defaults to 2; NM_CAP_DB selects the SQLite run store;
# NM_CAP_BINARY selects the underlying executable; NM_CAP_DRYRUN prints verdicts
# without changing enforcement. Defaults match the standard per-user install.
# Activation after review: install -m 755 bin/fm-nm-review-round-cap.sh
#   "$HOME/.no-mistakes/bin/review-round-cap.sh"
# The installed no-mistakes launcher must call that preflight before exec.
# Supported store contract: runs, step_results, and agent_invocations with
# one-based review rounds, purpose=review (review-fix invocations do not count).
cap=${NM_REVIEW_ROUND_CAP:-2}
db=${NM_CAP_DB:-"$HOME/.no-mistakes/state.sqlite"}
binary=${NM_CAP_BINARY:-"$HOME/.local/libexec/no-mistakes"}
say() { [ -n "${NM_CAP_DRYRUN:-}" ] && echo "review-round-cap: $*" >&2; }
refuse_unreadable() {
  echo "no-mistakes review-round cap: review round count could not be read. A further fix round is refused; escalate this review gate to firstmate for triage." >&2
  exit 3
}
safe() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._/:-]+$'; }
query() { sqlite3 -readonly "$db" "$1" 2>/dev/null; }

axi=0 respond=0 action='' run='' step='' expect=''
for arg in "$@"; do
  if [ -n "$expect" ]; then
    case "$expect" in
      action) action=$arg ;;
      run) run=$arg ;;
      step) step=$arg ;;
    esac
    expect=''
    continue
  fi
  case "$arg" in
    axi) axi=1 ;;
    respond) respond=1 ;;
    --action|--run|--step|--findings|--finding|--add-finding|--instructions|--wait)
      expect=${arg#--} ;;
    --action=*) action=${arg#--action=} ;;
    --run=*) run=${arg#--run=} ;;
    --step=*) step=${arg#--step=} ;;
    --*) ;;
    fix|approve|skip) if [ "$respond" = 1 ] && [ -z "$action" ]; then action=$arg; fi ;;
  esac
done
[ "$axi" = 1 ] && [ "$respond" = 1 ] && [ "$action" = fix ] || { say "not a fix answer: allow"; exit 0; }
[ -x "$binary" ] || { say "no-mistakes binary unavailable: allow"; exit 0; }
case "$cap" in ''|*[!0-9]*|0) refuse_unreadable ;; esac
command -v sqlite3 >/dev/null 2>&1 && [ -r "$db" ] || refuse_unreadable

if [ -z "$run" ]; then
  branch=$(git branch --show-current 2>/dev/null) || refuse_unreadable
  safe "$branch" || refuse_unreadable
  run=$(query "select id from runs where branch='$branch' order by created_at desc limit 1") || refuse_unreadable
fi
safe "$run" || refuse_unreadable

if [ -n "$step" ]; then
  safe "$step" || refuse_unreadable
  stepname=$(query "select step_name from step_results where run_id='$run' and (step_name='$step' or id='$step') limit 1") || refuse_unreadable
else
  stepname=$(query "select step_name from step_results where run_id='$run' and status in ('awaiting_approval','fix_review') limit 1") || refuse_unreadable
fi
[ -n "$stepname" ] || refuse_unreadable
[ "$stepname" = review ] || { say "step '$stepname' is not review: allow"; exit 0; }

rounds=$(query "select max(round) from agent_invocations where run_id='$run' and step_name='review' and purpose='review'") || refuse_unreadable
case "$rounds" in ''|*[!0-9]*|0) refuse_unreadable ;; esac
if [ "$rounds" -ge "$cap" ]; then
  echo "no-mistakes review-round cap: this change has already had $rounds review round(s); the limit is $cap (first review plus one re-review). A further fix round is refused. Escalate this review gate and its findings to firstmate for triage." >&2
  exit 3
fi
say "review round $rounds of $cap: fix allowed"
exit 0
