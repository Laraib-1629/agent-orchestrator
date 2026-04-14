#!/usr/bin/env node

import { readFileSync } from "node:fs";

function usage() {
  console.error("Usage: node experiments/summarize-gh-trace.mjs <trace.jsonl>");
  process.exit(1);
}

const tracePath = process.argv[2];
if (!tracePath) usage();

const raw = readFileSync(tracePath, "utf-8");
const lines = raw.split("\n").filter(Boolean);
const entries = lines.map((line) => JSON.parse(line));

const totals = {
  count: entries.length,
  ok: entries.filter((entry) => entry.ok).length,
  failed: entries.filter((entry) => !entry.ok).length,
};

const byOperation = new Map();
const byStatus = new Map();
let peakDurationMs = 0;

for (const entry of entries) {
  peakDurationMs = Math.max(peakDurationMs, Number(entry.durationMs) || 0);

  const operation = String(entry.operation ?? "unknown");
  byOperation.set(operation, (byOperation.get(operation) ?? 0) + 1);

  const status = entry.httpStatus === undefined ? "none" : String(entry.httpStatus);
  byStatus.set(status, (byStatus.get(status) ?? 0) + 1);
}

function printMap(title, map) {
  console.log(`\n${title}`);
  for (const [key, value] of [...map.entries()].sort((a, b) => {
    if (b[1] !== a[1]) return b[1] - a[1];
    return String(a[0]).localeCompare(String(b[0]));
  })) {
    console.log(`  ${key}: ${value}`);
  }
}

console.log(`Trace file: ${tracePath}`);
console.log(`Entries: ${totals.count}`);
console.log(`Succeeded: ${totals.ok}`);
console.log(`Failed: ${totals.failed}`);
console.log(`Longest request: ${peakDurationMs}ms`);

printMap("By operation", byOperation);
printMap("By HTTP status", byStatus);
