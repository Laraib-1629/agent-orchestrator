import { describe, expect, it } from "vitest";
import { buildZoneStats } from "../OrchestratorStatusStrip";

const EMPTY = { merge: 0, respond: 0, review: 0, pending: 0, working: 0, done: 0 };

describe("buildZoneStats", () => {
  it("returns no stats when every zone is zero", () => {
    expect(buildZoneStats(EMPTY)).toEqual([]);
  });

  it("filters out zones with a value of zero", () => {
    const stats = buildZoneStats({ ...EMPTY, merge: 2, working: 3 });
    expect(stats.map((s) => s.label)).toEqual(["merge-ready", "working"]);
  });

  it("preserves the canonical zone order: merge, respond, review, working, pending, done", () => {
    const stats = buildZoneStats({
      merge: 1,
      respond: 1,
      review: 1,
      working: 1,
      pending: 1,
      done: 1,
    });
    expect(stats.map((s) => s.label)).toEqual([
      "merge-ready",
      "responding",
      "review",
      "working",
      "pending",
      "done",
    ]);
  });

  it("ignores negative values just like zero", () => {
    const stats = buildZoneStats({ ...EMPTY, merge: -1, done: 4 });
    expect(stats.map((s) => s.label)).toEqual(["done"]);
  });
});
