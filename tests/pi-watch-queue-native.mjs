// Native Pi SDK queue/event regression. A deterministic local provider holds
// completions; no credentials, network, user home, or model reasoning is used.
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, cpSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL, fileURLToPath } from "node:url";
const source = resolve(dirname(fileURLToPath(import.meta.url)), "..");
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
  session.state.model = undefined;
  await fire(1);
  await waitFor(() => errors.length === 1, "rejected extension input was not reported", 1);
  await fire(2);
  await waitFor(() => errors.length === 2, "rejected extension input suppressed a later wake", 2);
  session.state.model = model;
  await fire();
  await waitFor(() => rows("confirmations").length === 4, "rejected input recovery was not confirmed", 2);
  await session.waitForIdle();
  assert.equal(rows("confirmations").length, 4, "rejected inputs lost their recovery identity");
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
  console.log(`ok - Pi ${JSON.parse(readFileSync(`${packageRoot}/package.json`, "utf8")).version} native SDK: busy batching, consumed/rejected input retry, replacement preflight, ${event} durable rows and ${rows("confirmations").length} consumed recovery confirmations`);
} finally {
  releaseBlockedInput?.();
  releaseAll = true;
  for (const finish of streams) finish(true);
  if (session) { await session.abort(); await session.reload(); session.dispose(); }
  clearTimeout(timeout);
  rmSync(lab, { recursive: true, force: true });
}
