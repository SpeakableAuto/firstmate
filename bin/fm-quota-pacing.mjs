#!/usr/bin/env node
// Pure quota pacing calculation. Quota-axi remains the source of measurements.
// Usage: fm-quota-pacing.mjs <config-json> <snapshot-json|-> [epoch-seconds]
// The output schema is owned by docs/configuration.md, "Quota pacing".
import { readFileSync } from 'node:fs';

const [configPath, snapshotPath, clock] = process.argv.slice(2);
if (!configPath || !snapshotPath || process.argv.length > 5) {
  console.error('usage: fm-quota-pacing.mjs <config-json> <snapshot-json|-> [epoch-seconds]');
  process.exit(2);
}

function fail(message) {
  console.error(`quota-pacing: ${message}`);
  process.exit(2);
}

let config;
let snapshot;
try {
  config = JSON.parse(readFileSync(configPath, 'utf8'));
  snapshot = JSON.parse(readFileSync(snapshotPath === '-' ? 0 : snapshotPath, 'utf8'));
} catch {
  fail('config or snapshot is unreadable JSON');
}

const now = clock === undefined ? Date.now() : Number(clock) * 1000;
if (!Number.isFinite(now)) fail('invalid clock');
if (!config || typeof config !== 'object' || Array.isArray(config)) fail('config must be an object');
if (Object.hasOwn(config, 'quota_pacing')
    && (!config.quota_pacing || typeof config.quota_pacing !== 'object'
      || Array.isArray(config.quota_pacing) || !Array.isArray(config.quota_pacing.accounts))) {
  fail('quota_pacing.accounts must be an array');
}
const entries = config.quota_pacing?.accounts ?? [];
if (!Array.isArray(entries)) fail('quota_pacing.accounts must be an array');
const seen = new Set();
for (const entry of entries) {
  if (!entry || typeof entry !== 'object' || Array.isArray(entry)) fail('invalid account entry');
  const { provider, account_key: accountKey = 'default', scope, window_id: windowId,
    window_seconds: duration, floor_percent: floor, max_concurrent: cap } = entry;
  if (![provider, accountKey, scope, windowId].every(value => typeof value === 'string' && value.length > 0)
      || !Number.isInteger(duration) || duration <= 0
      || typeof floor !== 'number' || floor < 0 || floor > 100
      || !Number.isInteger(cap) || cap < 1) fail('invalid quota_pacing account settings');
  const key = JSON.stringify([provider, accountKey, scope]);
  if (seen.has(key)) fail('duplicate quota_pacing account scope');
  seen.add(key);
}

const providers = Array.isArray(snapshot.providers) ? snapshot.providers : [snapshot];
const accounts = entries.map(entry => {
  const provider = entry.provider;
  const accountKey = entry.account_key ?? 'default';
  const row = providers.find(item => item?.provider === provider && (item.accountKey ?? 'default') === accountKey);
  const window = row?.windows?.find(item => item.id === entry.window_id);
  const reset = window?.resetsAt ? Date.parse(window.resetsAt) : NaN;
  const remaining = window?.percentRemaining;
  const base = {
    provider, accountKey, scope: entry.scope, windowId: entry.window_id,
    nextWindow: Number.isFinite(reset) ? new Date(reset).toISOString() : null,
    floorPercent: entry.floor_percent, maxConcurrency: entry.max_concurrent,
    remainingPercent: typeof remaining === 'number' ? remaining : null,
    pathPercent: null, allowedConcurrency: null, state: 'unknown', queuedTaskIds: [],
  };
  if (row?.state?.stale === true || row?.state?.status === 'stale'
      || typeof remaining !== 'number' || !Number.isFinite(remaining)
      || remaining < 0 || remaining > 100
      || !Number.isFinite(reset) || reset <= now) return base;
  const fraction = Math.min(1, Math.max(0, (reset - now) / (entry.window_seconds * 1000)));
  const path = entry.floor_percent + (100 - entry.floor_percent) * fraction;
  const aboveFloor = remaining >= entry.floor_percent;
  const ahead = remaining >= path;
  const ratio = path > entry.floor_percent
    ? (remaining - entry.floor_percent) / (path - entry.floor_percent)
    : 1;
  const allowed = aboveFloor
    ? (ahead ? entry.max_concurrent : Math.max(1, Math.min(entry.max_concurrent - 1, Math.ceil(entry.max_concurrent * ratio))))
    : 0;
  return {
    ...base,
    pathPercent: Math.round(path * 10000) / 10000,
    allowedConcurrency: allowed,
    state: !aboveFloor ? 'below_floor' : remaining === entry.floor_percent ? 'at_floor' : ahead ? 'ahead' : 'behind',
  };
});

process.stdout.write(`${JSON.stringify({ schemaVersion: 1, generatedAt: new Date(now).toISOString(), accounts })}\n`);
