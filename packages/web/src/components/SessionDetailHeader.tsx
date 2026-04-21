"use client";

import { useEffect, useRef, useState } from "react";
import { CI_STATUS } from "@aoagents/ao-core/types";
import { cn } from "@/lib/cn";
import {
  type DashboardSession,
  type DashboardPR,
  isPRMergeReady,
} from "@/lib/types";
import type { ProjectInfo } from "@/lib/project-name";
import { SessionDetailPRCard } from "./SessionDetailPRCard";
import { askAgentToFix } from "./session-detail-agent-actions";
import { buildGitHubBranchUrl } from "./session-detail-utils";

interface SessionDetailHeaderProps {
  session: DashboardSession;
  isOrchestrator: boolean;
  isMobile: boolean;
  terminalEnded: boolean;
  isRestorable: boolean;
  activity: { label: string; color: string };
  headline: string;
  projects: ProjectInfo[];
  orchestratorHref: string | null;
  onToggleSidebar: () => void;
  onRestore: () => void;
  onKill: () => void;
}

function normalizeActivityLabelForClass(activityLabel: string): string {
  return activityLabel.toLowerCase().replace(/\s+/g, "-");
}

export function SessionDetailHeader({
  session,
  isOrchestrator,
  isMobile,
  terminalEnded,
  isRestorable,
  activity,
  headline,
  projects,
  orchestratorHref,
  onToggleSidebar,
  onRestore,
  onKill,
}: SessionDetailHeaderProps) {
  const pr = session.pr;
  const allGreen = pr ? isPRMergeReady(pr) : false;
  const [prPopoverOpen, setPrPopoverOpen] = useState(false);
  const prPopoverRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!prPopoverOpen) return;
    const handler = (event: MouseEvent) => {
      if (prPopoverRef.current && !prPopoverRef.current.contains(event.target as Node)) {
        setPrPopoverOpen(false);
      }
    };
    const keyHandler = (event: KeyboardEvent) => {
      if (event.key === "Escape") setPrPopoverOpen(false);
    };
    document.addEventListener("mousedown", handler);
    document.addEventListener("keydown", keyHandler);
    return () => {
      document.removeEventListener("mousedown", handler);
      document.removeEventListener("keydown", keyHandler);
    };
  }, [prPopoverOpen]);

  const headerProjectLabel =
    projects.find((project) => project.id === session.projectId)?.name ?? session.projectId;
  const showHeaderProjectLabel =
    headerProjectLabel.trim().toLowerCase() !== "agent orchestrator";

  return (
    <header className="dashboard-app-header">
      {projects.length > 0 ? (
        <button
          type="button"
          className="dashboard-app-sidebar-toggle"
          onClick={onToggleSidebar}
          aria-label="Toggle sidebar"
        >
          {isMobile ? (
            <svg
              width="16"
              height="16"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              viewBox="0 0 24 24"
              aria-hidden="true"
            >
              <path d="M4 6h16M4 12h16M4 18h16" />
            </svg>
          ) : (
            <svg
              width="14"
              height="14"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.75"
              viewBox="0 0 24 24"
              aria-hidden="true"
            >
              <rect x="3" y="3" width="18" height="18" rx="2" />
              <path d="M9 3v18" />
            </svg>
          )}
        </button>
      ) : null}
      <div className="dashboard-app-header__brand dashboard-app-header__brand--hide-mobile">
        <span>Agent Orchestrator</span>
      </div>
      {showHeaderProjectLabel && (
        <span className="dashboard-app-header__sep topbar-desktop-only" aria-hidden="true" />
      )}
      <div className="topbar-project-pills-group">
        <div className="topbar-project-line">
          {showHeaderProjectLabel && (
            <span className="dashboard-app-header__project">{headerProjectLabel}</span>
          )}
          {!isOrchestrator && (
            <span className="dashboard-app-header__session-id topbar-mobile-only">
              {session.id}
            </span>
          )}
        </div>
        {!isOrchestrator && (
          <div className="topbar-session-pills">
            <div
              className={cn(
                "topbar-status-pill",
                `topbar-status-pill--${normalizeActivityLabelForClass(activity.label)}`,
              )}
            >
              <span
                className="topbar-status-pill__dot"
                style={{ background: activity.color }}
              />
              <span className="topbar-status-pill__label">{activity.label}</span>
            </div>
            {session.branch ? (
              pr ? (
                <a
                  href={buildGitHubBranchUrl(pr)}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="topbar-branch-pill topbar-branch-pill--link"
                >
                  {session.branch}
                </a>
              ) : (
                <span className="topbar-branch-pill">{session.branch}</span>
              )
            ) : null}
          </div>
        )}
      </div>
      {!isOrchestrator && (
        <>
          <span className="dashboard-app-header__sep topbar-desktop-only" aria-hidden="true" />
          <span className="dashboard-app-header__session-title topbar-desktop-only">
            {headline}
          </span>
          <span className="dashboard-app-header__session-id topbar-desktop-only">
            {session.id}
          </span>
        </>
      )}
      <div className="dashboard-app-header__spacer" />
      <div className="dashboard-app-header__actions">
        {pr ? (
          <div className="topbar-pr-btn-wrap" ref={prPopoverRef}>
            <a
              href={pr.url}
              target="_blank"
              rel="noopener noreferrer"
              className={cn(
                "dashboard-app-btn topbar-pr-btn",
                prPopoverOpen && "topbar-pr-btn--open",
              )}
              onClick={(event) => {
                if (event.metaKey || event.ctrlKey || event.shiftKey || event.button === 1) return;
                event.preventDefault();
                setPrPopoverOpen((value) => !value);
              }}
              aria-expanded={prPopoverOpen}
              aria-label={`PR #${pr.number}`}
            >
              <span
                className={cn(
                  "topbar-pr-dot",
                  allGreen
                    ? "topbar-pr-dot--green"
                    : pr.ciStatus === CI_STATUS.FAILING ||
                        pr.reviewDecision === "changes_requested"
                      ? "topbar-pr-dot--red"
                      : "topbar-pr-dot--amber",
                )}
              />
              PR #{pr.number}
              <svg
                width="10"
                height="10"
                fill="none"
                stroke="currentColor"
                strokeWidth="2.5"
                viewBox="0 0 24 24"
                aria-hidden="true"
              >
                <path d={prPopoverOpen ? "M18 15l-6-6-6 6" : "M6 9l6 6 6-6"} />
              </svg>
            </a>

            {prPopoverOpen && (
              <div className="topbar-pr-popover">
                <SessionDetailPRCard
                  pr={pr as DashboardPR}
                  metadata={session.metadata}
                  onAskAgentToFix={(comment, onSuccess, onError) =>
                    askAgentToFix(session.id, comment, onSuccess, onError)
                  }
                />
              </div>
            )}
          </div>
        ) : null}

        {isRestorable ? (
          <button type="button" className="dashboard-app-btn" onClick={onRestore}>
            <svg
              className="h-3 w-3"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              viewBox="0 0 24 24"
            >
              <polyline points="1 4 1 10 7 10" />
              <path d="M3.51 15a9 9 0 1 0 2.13-9.36L1 10" />
            </svg>
            <span className="topbar-btn-label">Restore</span>
          </button>
        ) : !isOrchestrator && !terminalEnded ? (
          <button
            type="button"
            className="dashboard-app-btn dashboard-app-btn--danger"
            onClick={onKill}
          >
            <svg
              className="h-3.5 w-3.5"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              viewBox="0 0 24 24"
            >
              <path d="M3 6h18M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
            </svg>
            <span className="topbar-btn-label">Kill</span>
          </button>
        ) : null}

        {!isOrchestrator && orchestratorHref ? (
          <a
            href={orchestratorHref}
            className="dashboard-app-btn dashboard-app-btn--amber topbar-desktop-only"
            aria-label="Orchestrator"
          >
            <svg
              width="12"
              height="12"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.6"
              viewBox="0 0 24 24"
              aria-hidden="true"
            >
              <circle cx="12" cy="5" r="2" fill="currentColor" stroke="none" />
              <path d="M12 7v4M12 11H6M12 11h6M6 11v3M12 11v3M18 11v3" />
              <circle cx="6" cy="17" r="2" />
              <circle cx="12" cy="17" r="2" />
              <circle cx="18" cy="17" r="2" />
            </svg>
            <span className="topbar-btn-label">Orchestrator</span>
          </a>
        ) : null}
      </div>
    </header>
  );
}
