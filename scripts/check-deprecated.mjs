#!/usr/bin/env node
// Fails CI if any @deprecated JSDoc tag is missing a decay marker.
//
// Every @deprecated must include one of:
//   - a version cutoff:  @deprecated v2.0 — ...
//   - a date cutoff:     @deprecated removeBy=2026-Q3 — ...
//
// Policy: without a cutoff, deprecation becomes permanent. See issue #1430.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(fileURLToPath(import.meta.url), "..", "..");
const SCAN_ROOTS = ["packages"];
const SCAN_EXTENSIONS = new Set([".ts", ".tsx"]);
const IGNORE_DIRS = new Set(["node_modules", "dist", ".next", "coverage"]);

// Matches: @deprecated v1 / v2.0 / v0.1.0 / removeBy=YYYY / removeBy=YYYY-QN / removeBy=YYYY-MM-DD
const CUTOFF_RE = /@deprecated\s+(v\d[\d.]*|removeBy=[\w-]+)/;
const TAG_RE = /@deprecated\b/;

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    if (IGNORE_DIRS.has(entry)) continue;
    const abs = join(dir, entry);
    const stat = statSync(abs);
    if (stat.isDirectory()) {
      walk(abs, out);
    } else if (stat.isFile()) {
      const dot = entry.lastIndexOf(".");
      if (dot >= 0 && SCAN_EXTENSIONS.has(entry.slice(dot))) {
        out.push(abs);
      }
    }
  }
  return out;
}

const violations = [];
for (const root of SCAN_ROOTS) {
  const absRoot = join(ROOT, root);
  let files;
  try {
    files = walk(absRoot);
  } catch (err) {
    if (err.code === "ENOENT") continue;
    throw err;
  }
  for (const file of files) {
    const lines = readFileSync(file, "utf8").split("\n");
    lines.forEach((line, idx) => {
      if (TAG_RE.test(line) && !CUTOFF_RE.test(line)) {
        violations.push({
          file: relative(ROOT, file),
          line: idx + 1,
          text: line.trim(),
        });
      }
    });
  }
}

if (violations.length > 0) {
  console.error("Found @deprecated tags without a decay marker:");
  console.error("");
  for (const v of violations) {
    console.error(`  ${v.file}:${v.line}  ${v.text}`);
  }
  console.error("");
  console.error("Every @deprecated must include a cutoff:");
  console.error("  @deprecated v2.0 — use newMethod()");
  console.error("  @deprecated removeBy=2026-Q3 — use newMethod()");
  console.error("");
  console.error("See issue #1430 for the policy rationale.");
  process.exit(1);
}
