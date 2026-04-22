"use client";

import { useEffect, useState } from "react";
import type { DashboardPR } from "@/lib/types";
import { SessionTopStrip } from "./SessionDetailTopStrip";

export interface OrchestratorZones {
  merge: number;
  respond: number;
  review: number;
  pending: number;
  working: number;
  done: number;
}

interface OrchestratorStatusStripProps {
  zones: OrchestratorZones;
  createdAt: string;
  headline: string;
  activityLabel: string;
  activityColor: string;
  branch: string | null;
  pr: DashboardPR | null;
  crumbHref: string;
  crumbLabel: string;
}

export interface ZoneStat {
  value: number;
  label: string;
  color: string;
  bg: string;
}

export function buildZoneStats(zones: OrchestratorZones): ZoneStat[] {
  const all: ZoneStat[] = [
    {
      value: zones.merge,
      label: "merge-ready",
      color: "var(--color-status-ready)",
      bg: "color-mix(in srgb, var(--color-status-ready) 10%, transparent)",
    },
    {
      value: zones.respond,
      label: "responding",
      color: "var(--color-status-error)",
      bg: "color-mix(in srgb, var(--color-status-error) 10%, transparent)",
    },
    {
      value: zones.review,
      label: "review",
      color: "var(--color-accent-orange)",
      bg: "color-mix(in srgb, var(--color-accent-orange) 10%, transparent)",
    },
    {
      value: zones.working,
      label: "working",
      color: "var(--color-accent-blue)",
      bg: "color-mix(in srgb, var(--color-accent-blue) 10%, transparent)",
    },
    {
      value: zones.pending,
      label: "pending",
      color: "var(--color-status-attention)",
      bg: "color-mix(in srgb, var(--color-status-attention) 10%, transparent)",
    },
    {
      value: zones.done,
      label: "done",
      color: "var(--color-text-tertiary)",
      bg: "color-mix(in srgb, var(--color-text-tertiary) 14%, transparent)",
    },
  ];
  return all.filter((s) => s.value > 0);
}

export function OrchestratorStatusStrip({
  zones,
  createdAt,
  headline,
  activityLabel,
  activityColor,
  branch,
  pr,
  crumbHref,
  crumbLabel,
}: OrchestratorStatusStripProps) {
  const [uptime, setUptime] = useState<string>("");

  useEffect(() => {
    const compute = () => {
      const diff = Date.now() - new Date(createdAt).getTime();
      const h = Math.floor(diff / 3_600_000);
      const m = Math.floor((diff % 3_600_000) / 60_000);
      setUptime(h > 0 ? `${h}h ${m}m` : `${m}m`);
    };
    compute();
    const id = setInterval(compute, 30_000);
    return () => clearInterval(id);
  }, [createdAt]);

  const stats = buildZoneStats(zones);
  const total =
    zones.merge + zones.respond + zones.review + zones.working + zones.pending + zones.done;

  return (
    <div className="mx-auto max-w-[1180px] px-5 pt-5 lg:px-8">
      <SessionTopStrip
        headline={headline}
        crumbId={headline}
        activityLabel={activityLabel}
        activityColor={activityColor}
        branch={branch}
        pr={pr}
        isOrchestrator
        crumbHref={crumbHref}
        crumbLabel={crumbLabel}
        rightSlot={
          <div className="flex flex-wrap items-center gap-3 lg:justify-end">
            <div className="flex items-baseline gap-1.5 mr-2">
              <span className="text-[22px] font-bold leading-none tabular-nums text-[var(--color-text-primary)]">
                {total}
              </span>
              <span className="text-[11px] text-[var(--color-text-tertiary)]">agents</span>
            </div>

            <div className="h-5 w-px bg-[var(--color-border-subtle)] mr-1" />

            {stats.length > 0 ? (
              stats.map((s) => (
                <div
                  key={s.label}
                  className="flex items-center gap-1.5 px-2.5 py-1"
                  style={{ background: s.bg }}
                >
                  <span
                    className="text-[15px] font-bold leading-none tabular-nums"
                    style={{ color: s.color }}
                  >
                    {s.value}
                  </span>
                  <span
                    className="text-[10px] font-medium"
                    style={{ color: s.color, opacity: 0.8 }}
                  >
                    {s.label}
                  </span>
                </div>
              ))
            ) : (
              <span className="text-[12px] text-[var(--color-text-tertiary)]">
                no active agents
              </span>
            )}

            {uptime ? (
              <span className="ml-auto font-[var(--font-mono)] text-[11px] text-[var(--color-text-tertiary)]">
                up {uptime}
              </span>
            ) : null}
          </div>
        }
      />
    </div>
  );
}
