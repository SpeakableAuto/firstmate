#!/usr/bin/env bash
# Opt-in credentialed Pi continuity regression on a private tmux socket and
# isolated project/home state. It uses the existing shared Pi auth store without
# copying credentials and pins the captain-approved openai-codex model.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${FM_PI_NATIVE_QUEUE:-0}" = 1 ]; then
  FM_PI_NATIVE_SOURCE_ROOT="$ROOT" exec node --input-type=module <<'JS'
// Native Pi SDK queue/event regression. A deterministic local provider holds
// completions; no credentials, network, user home, or model reasoning is used.
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, cpSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
const source = process.env.FM_PI_NATIVE_SOURCE_ROOT;
assert(source, "FM_PI_NATIVE_SOURCE_ROOT must name the repository root");
const packageRoot = process.env.FM_PI_PACKAGE_ROOT;
assert(packageRoot, "FM_PI_PACKAGE_ROOT must name the installed Pi coding-agent package");
const requirePi = createRequire(`${packageRoot}/package.json`);
const { createAgentSession, DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager } = await import(pathToFileURL(`${packageRoot}/dist/index.js`));
const aiRoot = requirePi.resolve.paths("@earendil-works/pi-ai").map((path) => `${path}/@earendil-works/pi-ai`).find((path) => existsSync(`${path}/package.json`));
assert(aiRoot, "installed Pi must include pi-ai");
const aiManifest = JSON.parse(readFileSync(`${aiRoot}/package.json`, "utf8"));
const { createAssistantMessageEventStream } = await import(pathToFileURL(resolve(aiRoot, aiManifest.exports["./compat"].import)));
const lab = mkdtempSync(`${tmpdir()}/fm-pi-queue-native-`);
const state = `${lab}/state`;
let session;
let releaseAll = false;
let inputMode = "continue";
let inputAttempts = 0;
let releaseBlockedInput;
const streams = [];
const timeout = setTimeout(() => { console.error("native Pi queue regression timed out"); process.exit(1); }, 60000);
try {
  for (const dir of [state, `${lab}/config`, `${lab}/bin`, `${lab}/.pi/extensions/lib`, `${lab}/agent`]) mkdirSync(dir, { recursive: true });
  for (const path of [".pi/extensions/fm-primary-pi-watch.ts", ".pi/extensions/lib/fm-operational-input.ts", ".pi/extensions/lib/fm-calm-visibility.ts", "bin/fm-operational-input.sh"]) cpSync(`${source}/${path}`, `${lab}/${path}`);
  writeFileSync(`${lab}/bin/fm-watch-arm.sh`, `#!/usr/bin/env bash
if [ "\${1:-}" = --handling-delivered ]; then
  latest=$(tail -n 1 "$FM_HOME/state/watcher-pids")
  [ "$4" = "$latest" ] || exit 9
  printf '%s %s\\n' "$2" "$4" >> "$FM_HOME/state/confirmations"
  exit 0
fi
printf 'arm\\n' >> "$FM_HOME/state/arms"
count=$(wc -l < "$FM_HOME/state/arms" | tr -d '[:space:]')
printf '%s\\n' "$$" >> "$FM_HOME/state/watcher-pids"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=native-generation\\n' "$$"
sleep 0.02
printf 'ready\\n' >> "$FM_HOME/state/readies"
trap 'exit 0' TERM INT
while [ ! -e "$FM_HOME/state/fire-$count" ]; do sleep 0.02; done
printf 'signal: native event %s\\n' "$count"
`, { mode: 0o755 });
  process.env.FM_HOME = lab;
  process.env.FM_ROOT_OVERRIDE = lab;
  process.env.FM_STATE_OVERRIDE = state;
  process.env.FM_CONFIG_OVERRIDE = `${lab}/config`;
  writeFileSync(`${state}/.lock`, `${process.pid}\n`);
  const model = { id: "queue-fixture", name: "Queue fixture", provider: "queue-fixture", api: "queue-fixture", baseUrl: "http://127.0.0.1:1", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 100000, maxTokens: 1000 };
  const settingsManager = SettingsManager.inMemory({ compaction: { enabled: false }, retry: { enabled: false } });
  const loader = new DefaultResourceLoader({
    cwd: lab, agentDir: `${lab}/agent`, settingsManager,
    noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
    additionalExtensionPaths: [`${lab}/.pi/extensions/fm-primary-pi-watch.ts`],
    extensionFactories: [(pi) => {
      pi.on("input", async (event) => {
        if (event.source !== "extension") return;
        inputAttempts++;
        if (inputMode === "transform") return { action: "transform", text: `TRANSFORMED PREFIX\n${event.text}\nTRANSFORMED SUFFIX` };
        if (inputMode === "handled") return { action: "handled" };
        if (inputMode === "blocked") {
          await new Promise((resolve) => { releaseBlockedInput = resolve; });
          return { action: "handled" };
        }
      });
      pi.registerProvider("queue-fixture", {
        api: "queue-fixture", apiKey: "local-fixture", baseUrl: model.baseUrl,
        models: [model],
        streamSimple: (_model, _context, options) => {
          const stream = createAssistantMessageEventStream();
          let ended = false;
          const finish = (abort = false) => {
            if (ended) return;
            ended = true;
            const output = { role: "assistant", content: [{ type: "text", text: "fixture response" }], api: model.api, provider: model.provider, model: model.id, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: abort ? "aborted" : "stop", timestamp: Date.now() };
            stream.push(abort ? { type: "error", reason: "aborted", error: output } : { type: "done", reason: "stop", message: output });
            stream.end();
          };
          streams.push(finish);
          options?.signal?.addEventListener("abort", () => finish(true), { once: true });
          if (releaseAll) queueMicrotask(() => finish());
          return stream;
        },
      });
    }],
  });
  await loader.reload();
  assert.deepEqual(loader.getExtensions().errors, [], "native extensions failed to load");
  const modelRuntime = await ModelRuntime.create({ authPath: `${lab}/agent/auth.json`, modelsPath: `${lab}/agent/models.json`, modelsStorePath: `${lab}/agent/store.json`, allowModelNetwork: false });
  ({ session } = await createAgentSession({ cwd: lab, agentDir: `${lab}/agent`, model, modelRuntime, settingsManager, resourceLoader: loader, sessionManager: SessionManager.inMemory(lab), tools: [] }));
  const errors = [];
  await session.bindExtensions({ onError: (error) => errors.push(error) });
  await session.prompt("/fm-watch-arm-pi");
  const rows = (file) => existsSync(`${state}/${file}`) ? readFileSync(`${state}/${file}`, "utf8").trim().split("\n").filter(Boolean) : [];
  async function waitFor(test, label, allowedErrors = 0) {
    for (let i = 0; i < 500; i++) {
      if (test()) return;
      if (errors.length > allowedErrors) throw new Error(JSON.stringify(errors));
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    throw new Error(`${label}; messages=${JSON.stringify(session.state.messages)}`);
  }
  let event = 0;
  async function fire(allowedErrors = errors.length) {
    const cycle = rows("arms").length;
    writeFileSync(`${state}/.wake-queue`, [...rows(".wake-queue"), `1\t${++event}\tsignal\tjob-${event}\tevent-${event}`].join("\n") + "\n");
    writeFileSync(`${state}/fire-${cycle}`, "fire\n");
    await waitFor(() => rows("arms").length > cycle && rows("readies").length > cycle, "native wake did not restore", allowedErrors);
  }
  await waitFor(() => rows("arms").length === 1, "native watcher command did not arm");
  const run = session.prompt("CAPTAIN_FIRST");
  await waitFor(() => streams.length === 1, "local provider did not start");
  for (let i = 0; i < 10; i++) await fire();
  assert.equal(session.getFollowUpMessages().length, 1, "busy burst produced redundant Pi follow-ups");
  await session.steer("CAPTAIN_STEERING");
  assert.equal(session.getSteeringMessages().length, 1, "captain steering disappeared");
  streams[0]();
  await waitFor(() => streams.length === 2, "steering did not reach next native turn");
  assert(session.state.messages.some((m) => m.role === "user" && JSON.stringify(m.content).includes("CAPTAIN_STEERING")));
  assert.equal(session.getFollowUpMessages().length, 1, "user steering released the watcher slot");
  assert.equal(rows("confirmations").length, 0, "unrelated steering confirmed watcher recovery");
  streams[1]();
  await waitFor(() => streams.length === 3, "watcher hint did not enter native handling turn");
  await waitFor(() => rows("confirmations").length === 1, "coalesced recovery was not confirmed at message_start");
  assert.equal(session.getFollowUpMessages().length, 0);
  for (let i = 0; i < 10; i++) await fire();
  assert.equal(session.getFollowUpMessages().length, 1, "new events during handling were lost or duplicated");
  // Pi's UI can restore queued messages to the editor when aborting. Exercise
  // that public clearQueue boundary before abort rather than fake event ordering.
  const removed = session.clearQueue();
  assert.equal(removed.followUp.length, 1);
  const aborted = session.abort();
  streams.at(-1)(true);
  await aborted;
  await run;
  assert.equal(session.getFollowUpMessages().length, 0);
  releaseAll = true;
  await fire();
  await waitFor(() => rows("confirmations").length === 2, "discarded hint recovery was not confirmed");
  await session.waitForIdle();
  assert.equal(session.getFollowUpMessages().length, 0, "settled discarded hint suppressed later wake");
  assert.equal(rows("confirmations").length, 2, "discarded hint lost its recovery identity");
  inputMode = "handled";
  let attempts = inputAttempts;
  await fire();
  await waitFor(() => inputAttempts === attempts + 1, "handled extension input was not attempted");
  await fire();
  await waitFor(() => inputAttempts === attempts + 2, "handled extension input suppressed a later wake");
  inputMode = "continue";
  await fire();
  await waitFor(() => rows("confirmations").length === 3, "handled input recovery was not confirmed");
  await session.waitForIdle();
  assert.equal(rows("confirmations").length, 3, "handled inputs lost their recovery identity");
  inputMode = "transform";
  const messagesBeforeTransform = session.state.messages.length;
  await fire();
  await waitFor(() => rows("confirmations").length === 4, "transformed input recovery was not confirmed");
  await session.waitForIdle();
  const transformedMessages = session.state.messages.slice(messagesBeforeTransform).filter((message) => message.role === "user");
  assert(transformedMessages.some((message) => {
    const text = JSON.stringify(message.content);
    return text.includes("TRANSFORMED PREFIX") && text.includes("TRANSFORMED SUFFIX");
  }), "native input transform did not reach message_start");
  inputMode = "continue";
  session.state.model = undefined;
  await fire(1);
  await waitFor(() => errors.length === 1, "rejected extension input was not reported", 1);
  await fire(2);
  await waitFor(() => errors.length === 2, "rejected extension input suppressed a later wake", 2);
  session.state.model = model;
  await fire();
  await waitFor(() => rows("confirmations").length === 5, "rejected input recovery was not confirmed", 2);
  await session.waitForIdle();
  assert.equal(rows("confirmations").length, 5, "rejected inputs lost their recovery identity");
  inputMode = "blocked";
  attempts = inputAttempts;
  await fire();
  await waitFor(() => inputAttempts === attempts + 1 && releaseBlockedInput, "blocked extension preflight did not start", 2);
  const confirmationsBeforeReload = rows("confirmations").length;
  const armsBeforeReload = rows("arms").length;
  await session.reload();
  await session.prompt("/fm-watch-arm-pi");
  await waitFor(() => rows("arms").length === armsBeforeReload + 1, "reloaded watcher did not arm", 2);
  inputMode = "continue";
  await fire();
  await waitFor(() => rows("confirmations").length === confirmationsBeforeReload + 1, "replacement recovery was not confirmed", 2);
  await session.waitForIdle();
  assert.equal(rows("confirmations").length, confirmationsBeforeReload + 1, "replacement recovery was not confirmed at message_start");
  releaseBlockedInput();
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(rows("confirmations").length, confirmationsBeforeReload + 1, "replaced preflight confirmed stale recovery");
  assert.equal(rows(".wake-queue").length, event, "native bridge consumed durable work");
  assert(errors.every((error) => error.event === "send_user_message" && error.error.includes("No model selected")), JSON.stringify(errors));
  console.log(`ok - Pi ${JSON.parse(readFileSync(`${packageRoot}/package.json`, "utf8")).version} native SDK: busy batching, transformed/consumed/rejected input, replacement preflight, ${event} durable rows and ${rows("confirmations").length} consumed recovery confirmations`);
} finally {
  releaseBlockedInput?.();
  releaseAll = true;
  for (const finish of streams) finish(true);
  if (session) { await session.abort(); await session.reload(); session.dispose(); }
  clearTimeout(timeout);
  rmSync(lab, { recursive: true, force: true });
}
JS
fi

if [ "${FM_PI_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_LIVE_E2E=1 to run the isolated interactive Pi regression"
  exit 0
fi

unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v pi >/dev/null 2>&1 || fail "pi not found"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"

TMUX=$(command -v tmux)
SOCKET="fm-pi-live-e2e-$$"
SESSION=pi-live-e2e
LAB="$ROOT/.pi-live-e2e.$$"
PROJECT="$LAB/project"
AHOY_PROJECT="$LAB/ahoy-project"
HOME_DIR="$LAB/fmhome"
PI_VERSION=$(pi --version)
# shellcheck source=/dev/null
. "$ROOT/bin/fm-operational-input.sh"
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
LEGACY_START='Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
LEGACY_AWAY=$'\xE2\x81\xA3Supervisor escalate (1 event(s)): done: legacy rollout'
MARKER_NEAR_MISS=$'\xE2\x81\xA3Captain note: this invisible separator is intentional.'
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
START_NEAR_MISS='Captain quote: Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
fm_operational_input_encode watcher "CURRENT_AHOY_WATCHER_BODY" CURRENT_WATCHER \
  || fail "could not construct current Ahoy watcher fixture"
QUOTED_CURRENT="Captain quote: $CURRENT_WATCHER"
ASCII_ONLY='FIRSTMATE_OP: v1 watcher: captain-authored text'

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -600 2>/dev/null || true
}

wait_for_text() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fq "$expected"; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

wait_for_exact_line() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fxq " $expected"; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

lab_pid_is_safe() {
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local pid_file watcher_pid arm_pid
  pid_file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid 2>/dev/null | head -1 || true)
  watcher_pid=
  arm_pid=
  if [ -n "$pid_file" ]; then
    watcher_pid=$(sed -n '1p' "$pid_file" 2>/dev/null || true)
    arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  fi
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  sleep 0.1
  if [ -n "$watcher_pid" ] && lab_pid_is_safe "$watcher_pid"; then
    kill -TERM "$watcher_pid" 2>/dev/null || true
  fi
  if [ -n "$arm_pid" ] && lab_pid_is_safe "$arm_pid"; then
    kill -TERM "$arm_pid" 2>/dev/null || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

send_prompt() {
  local prompt=$1
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$prompt"
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
}

wait_pid_dead() {
  local pid=$1 i=0
  while [ "$i" -lt 50 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

run_ahoy_case() {
  local label=$1 preceding=$2 expected=$3 out status=0
  out=$(
    cd "$PROJECT" &&
      pi --print --approve --no-session --no-context-files --no-extensions \
        --no-skills --skill .agents/skills --tools read \
        --model openai-codex/gpt-5.6-sol --thinking low \
        "$preceding" "/ahoy"
  ) || status=$?
  [ "$status" -eq 0 ] || fail "Pi Ahoy $label case exited $status: $out"
  case "$expected" in
    bearings)
      printf '%s\n' "$out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
        || fail "Pi Ahoy $label case did not take Bearings: $out"
      ;;
    boundary)
      printf '%s\n' "$out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
        && fail "Pi Ahoy $label near miss was treated as operational: $out"
      ;;
  esac
}

run_ahoy_transcript_regressions() {
  mkdir -p "$PROJECT/.agents/skills/ahoy" "$PROJECT/.agents/skills/bearings"
  cp "$ROOT/.agents/skills/ahoy/SKILL.md" "$PROJECT/.agents/skills/ahoy/SKILL.md"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  printf '%s\n' \
    '---' \
    'name: bearings' \
    'description: Test-only Bearings branch sentinel.' \
    '---' \
    '' \
    '# bearings' \
    '' \
    'Respond exactly `AHOY_BEARINGS_BRANCH`.' \
    > "$PROJECT/.agents/skills/bearings/SKILL.md"

  run_ahoy_case legacy-start "$LEGACY_START" bearings
  run_ahoy_case legacy-away "$LEGACY_AWAY" bearings
  run_ahoy_case marker-near-miss "$MARKER_NEAR_MISS" boundary
  run_ahoy_case startup-near-miss "$START_NEAR_MISS" boundary
  run_ahoy_case quoted-current "$QUOTED_CURRENT" boundary
  run_ahoy_case ascii-only "$ASCII_ONLY" boundary
}

run_native_ahoy_regressions() {
  local first_home="$LAB/pi-ahoy-first-home"
  local later_home="$LAB/pi-ahoy-later-home"
  local first_out later_out

  mkdir -p \
    "$AHOY_PROJECT/.pi/extensions/lib" \
    "$AHOY_PROJECT/.agents/skills/ahoy" \
    "$AHOY_PROJECT/.agents/skills/bearings" \
    "$AHOY_PROJECT/bin" \
    "$first_home/state" "$first_home/config" \
    "$later_home/state" "$later_home/config"
  git init -q "$AHOY_PROJECT"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$AHOY_PROJECT/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$AHOY_PROJECT/.pi/extensions/lib/"
  cp \
    "$ROOT/bin/fm-sessionstart-nudge.sh" \
    "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-gate-refuse-lib.sh" \
    "$ROOT/bin/fm-operational-input.sh" \
    "$AHOY_PROJECT/bin/"
  cp "$ROOT/.agents/skills/ahoy/SKILL.md" "$AHOY_PROJECT/.agents/skills/ahoy/SKILL.md"
  chmod +x "$AHOY_PROJECT/bin/fm-sessionstart-nudge.sh"
  # shellcheck disable=SC2016 # Variables expand in the generated script, not this test shell.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'file="${FM_HOME:?}/state/session-start-count"' \
    'count=0' \
    '[ ! -f "$file" ] || count=$(sed -n "1p" "$file")' \
    'count=$((count + 1))' \
    'printf "%s\n" "$count" > "$file"' \
    'printf "SESSION_START_DONE count=%s\n" "$count"' \
    > "$AHOY_PROJECT/bin/fm-session-start.sh"
  chmod +x "$AHOY_PROJECT/bin/fm-session-start.sh"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  printf '%s\n' \
    '---' \
    'name: bearings' \
    'description: Test-only Bearings branch sentinel.' \
    '---' \
    '' \
    '# bearings' \
    '' \
    'Respond exactly `AHOY_BEARINGS_BRANCH`.' \
    > "$AHOY_PROJECT/.agents/skills/bearings/SKILL.md"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  printf '%s\n' \
    '# Native Pi Ahoy regression fixture' \
    '' \
    'Run `bin/fm-session-start.sh` exactly once at session start.' \
    > "$AHOY_PROJECT/AGENTS.md"

  first_out=$(
    cd "$AHOY_PROJECT" &&
      FM_HOME="$first_home" pi --print --approve --no-session --no-context-files --no-extensions \
        -e .pi/extensions/fm-primary-turnend-guard.ts \
        --no-skills --skill .agents/skills \
        --model openai-codex/gpt-5.6-sol --thinking low \
        "/ahoy"
  )
  printf '%s\n' "$first_out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
    || fail "Pi native first-message Ahoy did not take Bearings: $first_out"
  [ "$(sed -n '1p' "$first_home/state/session-start-count")" = 1 ] \
    || fail "Pi native first-message Ahoy did not preserve one session-start execution"

  later_out=$(
    cd "$AHOY_PROJECT" &&
      FM_HOME="$later_home" pi --print --approve --no-session --no-context-files --no-extensions \
        -e .pi/extensions/fm-primary-turnend-guard.ts \
        --no-skills --skill .agents/skills \
        --model openai-codex/gpt-5.6-sol --thinking low \
        "Respond exactly PRIOR_BOUNDARY_ACK." "/ahoy"
  )
  printf '%s\n' "$later_out" | grep -Fq "PRIOR_BOUNDARY_ACK" \
    || fail "Pi native later-message setup did not preserve the genuine captain boundary: $later_out"
  printf '%s\n' "$later_out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
    && fail "Pi native later-message Ahoy gathered Bearings: $later_out"
  [ "$(sed -n '1p' "$later_home/state/session-start-count")" = 1 ] \
    || fail "Pi native later-message Ahoy reran session start"
}

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
run_ahoy_transcript_regressions
run_native_ahoy_regressions
mkdir -p "$PROJECT/.pi/extensions/lib"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$PROJECT/.pi/extensions/fm-calm.ts"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$PROJECT/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$PROJECT/.pi/extensions/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$PROJECT/.pi/extensions/lib/fm-operational-input.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-watch-arm.sh"
cp "$ROOT/bin/fm-operational-input.sh" "$PROJECT/bin/fm-operational-input.sh"
cp "$ROOT/bin/fm-supervision-instructions.sh" "$PROJECT/bin/fm-supervision-instructions.sh"
chmod +x "$PROJECT/bin/fm-operational-input.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"

"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; pi --approve --no-session --no-context-files --no-extensions -e .pi/extensions/fm-calm.ts -e .pi/extensions/fm-primary-turnend-guard.ts -e .pi/extensions/fm-primary-pi-watch.ts --model openai-codex/gpt-5.6-sol --thinking low; rc=\$?; printf \"PI_EXIT=%s\\n\" \"\$rc\"; sleep 300'"

i=0
while [ "$i" -lt 120 ]; do
  [ -f "$HOME_DIR/state/.pi-turnend-extension-loaded" ] && [ -f "$HOME_DIR/state/.pi-watch-extension-loaded" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ -f "$HOME_DIR/state/.pi-turnend-extension-loaded" ] || fail "Pi turn-end extension did not load"
[ -f "$HOME_DIR/state/.pi-watch-extension-loaded" ] || fail "Pi watcher extension did not load"
wait_for_text "(openai-codex)" 120 || fail "Pi did not reach its ready composer"
sleep 1

send_prompt "/calm"
sleep 0.2
send_prompt "Reply exactly CALM_LIVE_WORKING_VISIBLE"
i=0
while [ "$i" -lt 240 ]; do
  pane=$(capture)
  if printf '%s\n' "$pane" | grep -Fq '\__/'; then
    break
  fi
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$pane" | grep -Fq '\__/' \
  || fail "Calm did not show the working ship on the credentialed provider path"
printf '%s\n' "$pane" | grep -Fq "Working..." \
  && fail "Calm left Pi's stock working row visible on the credentialed provider path"
wait_for_exact_line "CALM_LIVE_WORKING_VISIBLE" 120 \
  || fail "Pi did not settle the Calm working-ship provider probe"
pane=$(capture)
printf '%s\n' "$pane" | grep -Fq '\__/' \
  && fail "Calm left the working ship on screen after the run settled"
printf '%s\n' "$pane" | grep -Fq "calm transcript" \
  && fail "Calm added a persistent Calm status row on the credentialed provider path"
send_prompt "/calm"
sleep 0.2

: > "$HOME_DIR/state/pi-e2e.meta"
send_prompt "Start supervision with fm_watch_arm_pi and never use bash to arm supervision. After the watcher wake arrives, run bin/fm-wake-drain.sh and reply exactly HANDLED."
wait_for_text "watcher: started Pi extension arm child 1" || fail "Pi did not render the initial watcher tool result"

printf 'done: pi live e2e watcher fire\n' > "$HOME_DIR/state/pi-e2e.status"
i=0
while [ "$i" -lt 240 ]; do
  grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null \
  || fail "Pi extension did not start and ledger-link a successor after the actionable close"
wait_for_exact_line "HANDLED" 120 || fail "Pi did not drain and settle after its extension-owned successor started"

pane=$(capture)
guard_count=$(printf '%s\n' "$pane" | grep -Fc "TURN WOULD END BLIND - supervision is off." || true)
[ "$guard_count" -eq 0 ] || fail "successor was not protecting Pi before its next turn end (guard count $guard_count)"
foreground_arm='$ bin/fm-watch-arm.sh'
if printf '%s\n' "$pane" | grep -Fq "$foreground_arm"; then
  fail "Pi used a foreground bash watcher arm"
fi
arm_tool_result_count=$(printf '%s\n' "$pane" | grep -Ec 'watcher: (started|unchanged|not armed|read-only)' || true)
[ "$arm_tool_result_count" -eq 1 ] || fail "Pi model re-armed from memory instead of the extension (tool-result count $arm_tool_result_count)"

pid_file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid | head -1)
[ -n "$pid_file" ] || fail "re-armed watcher pid was not recorded"
watcher_pid=$(sed -n '1p' "$pid_file")
arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
[ -n "$arm_pid" ] || fail "re-armed watcher parent was not live"

"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l '/quit'
sleep 1
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_text "PI_EXIT=0" 60 || fail "Pi did not exit cleanly"
wait_pid_dead "$watcher_pid" || fail "watcher child survived clean Pi exit"
wait_pid_dead "$arm_pid" || fail "arm child survived clean Pi exit"

printf 'ok - Pi %s live E2E covered the Calm working ship, Ahoy first/later messages, legacy transcripts, near misses, and watcher continuity\n' "$PI_VERSION"
