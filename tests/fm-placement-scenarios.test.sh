#!/usr/bin/env bash
# Exact placement regressions; optional scenario id selects one replay.
# FM_TEST_PLACEMENT_GATE_DISABLED=1 uses the real unconfigured-home bypass.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-placement-scenarios)
python3 "$ROOT/tests/fm-placement-scenarios.py" "$ROOT" "$TMP_ROOT" "${1:-}"
