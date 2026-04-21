/**
 * Orchestrator bootstrap — shared startup logic for `ao start`.
 *
 * Launches the dashboard (unless --no-dashboard), spins up the lifecycle worker,
 * and creates/reuses/restores an orchestrator session. Used by both the
 * normal and URL-based start flows.
 */

import { existsSync } from "node:fs";
import { resolve } from "node:path";
import type { ChildProcess } from "node:child_process";
import chalk from "chalk";
import ora from "ora";
import {
  generateOrchestratorPrompt,
  generateSessionPrefix,
  normalizeOrchestratorSessionStrategy,
  isOrchestratorSession,
  isTerminalSession,
  isRestorable,
  type OrchestratorConfig,
  type ProjectConfig,
  type Session,
} from "@aoagents/ao-core";
import { getSessionManager } from "./create-session-manager.js";
import { ensureLifecycleWorker } from "./lifecycle-service.js";
import {
  findWebDir,
  waitForPortAndOpen,
  isPortAvailable,
  findFreePort,
  MAX_PORT_SCAN,
} from "./web-dir.js";
import { rebuildDashboardProductionArtifacts } from "./dashboard-rebuild.js";
import { preflight } from "./preflight.js";
import { preventIdleSleep } from "./prevent-sleep.js";
import { applyOpenClawCredentials } from "./credential-resolver.js";
import { detectOpenClawInstallation } from "./openclaw-probe.js";
import { DEFAULT_PORT } from "./constants.js";
import { projectSessionUrl } from "./routes.js";
import { ensureTmux } from "./installer.js";
import { startDashboard } from "./dashboard-bootstrap.js";

async function warnAboutOpenClawStatus(config: OrchestratorConfig): Promise<void> {
  const openclawConfig = config.notifiers?.["openclaw"];
  const openclawConfigured =
    openclawConfig !== null && openclawConfig !== undefined &&
    typeof openclawConfig === "object" &&
    openclawConfig.plugin === "openclaw";
  const configuredUrl =
    openclawConfigured && typeof openclawConfig.url === "string" ? openclawConfig.url : undefined;

  try {
    const installation = configuredUrl
      ? await detectOpenClawInstallation(configuredUrl)
      : await detectOpenClawInstallation();

    if (openclawConfigured) {
      if (installation.state !== "running") {
        console.log(
          chalk.yellow(
            `⚠ OpenClaw is configured but the gateway is not reachable at ${installation.gatewayUrl}. Notifications may fail until it is running.`,
          ),
        );
      }
      return;
    }

    if (installation.state === "running") {
      console.log(
        chalk.yellow(
          `⚠ OpenClaw is running at ${installation.gatewayUrl} but AO is not configured to use it. Run \`ao setup openclaw\` if you want OpenClaw notifications.`,
        ),
      );
    }
  } catch {
    // OpenClaw probing is advisory for `ao start`; never block startup on it.
  }
}

export interface RunStartupOptions {
  dashboard?: boolean;
  orchestrator?: boolean;
  rebuild?: boolean;
  dev?: boolean;
}

/**
 * Shared startup logic: launch dashboard + orchestrator session, print summary.
 * Used by both normal and URL-based start flows.
 */
export async function runStartup(
  config: OrchestratorConfig,
  projectId: string,
  project: ProjectConfig,
  opts?: RunStartupOptions,
): Promise<number> {
  // Ensure tmux is available before doing anything — covers all entry paths
  // (normal start, URL start, retry with existing config)
  const runtime = config.defaults?.runtime ?? "tmux";
  if (runtime === "tmux") {
    await ensureTmux();
  }
  await warnAboutOpenClawStatus(config);

  // Prevent macOS idle sleep while AO is running (if enabled in config)
  // Uses caffeinate -i -w <pid> to hold an assertion tied to this process lifetime.
  // No-op on non-macOS platforms.
  if (config.power?.preventIdleSleep !== false) {
    const sleepHandle = preventIdleSleep();
    if (sleepHandle) {
      console.log(chalk.dim("  Preventing macOS idle sleep while AO is running"));
    }
  }

  // Only inject OpenClaw credentials when the project actually uses OpenClaw.
  // This avoids exposing API keys to projects/plugins that don't need them.
  const openclawNotifier = config.notifiers?.["openclaw"];
  const hasOpenClaw =
    openclawNotifier !== null && openclawNotifier !== undefined &&
    typeof openclawNotifier === "object" && openclawNotifier.plugin === "openclaw";
  if (hasOpenClaw) {
    const injectedKeys = applyOpenClawCredentials();
    if (injectedKeys.length > 0) {
      const names = injectedKeys.map((k) => k.key).join(", ");
      console.log(chalk.dim(`  Resolved from OpenClaw config: ${names}`));
    }
  }

  const shouldStartLifecycle = opts?.dashboard !== false || opts?.orchestrator !== false;
  let lifecycleStatus: Awaited<ReturnType<typeof ensureLifecycleWorker>> | null = null;
  let port = config.port ?? DEFAULT_PORT;
  const orchestratorSessionStrategy = normalizeOrchestratorSessionStrategy(
    project.orchestratorSessionStrategy,
  );

  console.log(chalk.bold(`\nStarting orchestrator for ${chalk.cyan(project.name)}\n`));

  const spinner = ora();
  let dashboardProcess: ChildProcess | null = null;
  let reused = false;
  let restored = false;

  // Start dashboard (unless --no-dashboard)
  if (opts?.dashboard !== false) {
    if (!(await isPortAvailable(port))) {
      const newPort = await findFreePort(port + 1);
      if (newPort === null) {
        throw new Error(
          `Port ${port} is busy and no free port found in range ${port + 1}–${port + MAX_PORT_SCAN}. Free port ${port} or set a different 'port' in agent-orchestrator.yaml.`,
        );
      }
      console.log(chalk.yellow(`Port ${port} is busy — using ${newPort} instead.`));
      port = newPort;
    }
    const webDir = findWebDir(); // throws with install-specific guidance if not found
    // Dev mode (HMR) only works in the monorepo where `server/` source exists.
    // For npm installs, --dev is silently ignored and production server runs,
    // so preflight must still verify production artifacts exist.
    const isMonorepo = existsSync(resolve(webDir, "server"));
    const willUseDevServer = isMonorepo && opts?.dev === true;
    if (opts?.rebuild) {
      await rebuildDashboardProductionArtifacts(webDir);
    } else if (!willUseDevServer) {
      await preflight.checkBuilt(webDir);
    }

    spinner.start("Starting dashboard");
    dashboardProcess = await startDashboard(
      port,
      webDir,
      config.configPath,
      config.terminalPort,
      config.directTerminalPort,
      opts?.dev,
    );
    spinner.succeed(`Dashboard starting on http://localhost:${port}`);
    console.log(chalk.dim("  (Dashboard will be ready in a few seconds)\n"));
  }

  if (shouldStartLifecycle) {
    try {
      spinner.start("Starting lifecycle worker");
      lifecycleStatus = await ensureLifecycleWorker(config, projectId);
      spinner.succeed(
        lifecycleStatus.started
          ? "Lifecycle polling started"
          : "Lifecycle polling already running",
      );
    } catch (err) {
      spinner.fail("Lifecycle worker failed to start");
      if (dashboardProcess) {
        dashboardProcess.kill();
      }
      throw new Error(
        `Failed to start lifecycle worker: ${err instanceof Error ? err.message : String(err)}`,
        { cause: err },
      );
    }
  }

  // Create orchestrator session (unless --no-orchestrator or existing orchestrators found)
  let hasMultipleReusable = false;
  let selectedOrchestratorId: string | null = null;
  let otherCandidateCount = 0;

  if (opts?.orchestrator !== false) {
    const sm = await getSessionManager(config);

    // Check for existing orchestrator sessions for this project.
    let allSessions;
    try {
      allSessions = await sm.list(projectId);
    } catch (err) {
      spinner.fail("Failed to list sessions");
      if (dashboardProcess) {
        dashboardProcess.kill();
      }
      throw new Error(
        `Failed to list sessions: ${err instanceof Error ? err.message : String(err)}`,
        { cause: err },
      );
    }
    const allSessionPrefixes = Object.entries(config.projects).map(
      ([, p]) => p.sessionPrefix ?? generateSessionPrefix(p.name ?? ""),
    );
    const orchestrators = allSessions.filter((s) =>
      isOrchestratorSession(s, project.sessionPrefix ?? projectId, allSessionPrefixes),
    );

    // Partition into two reuse buckets so we never spawn a new numbered id when
    // an existing one is still usable:
    //   - live:       runtime is still running, attach in place.
    //   - restorable: status is terminal but the session can be restarted via
    //                 sm.restore() (workspace + branch + handle still on disk).
    //                 Restoring keeps the original numbered id rather than
    //                 allocating a fresh one.
    //
    // IMPORTANT: live MUST be preferred unconditionally over restorable. A
    // previous version sorted both buckets together by `lastActivityAt`, which
    // could pick a newer killed record over an older-but-still-running one —
    // sm.restore() would then spin up the killed record while the live one
    // kept running, leaving two orchestrators alive for the project. Only fall
    // back to restorable when the live bucket is empty.
    const live = orchestrators.filter((s) => !isTerminalSession(s));
    // isRestorable already requires isTerminalSession internally, so no need
    // to repeat that guard here.
    const restorable = orchestrators.filter((s) => isRestorable(s));
    type OrchestratorCandidate = { session: Session; mode: "live" | "restore" };
    const byMostRecent = (a: Session, b: Session): number =>
      (b.lastActivityAt?.getTime() ?? 0) - (a.lastActivityAt?.getTime() ?? 0);
    const candidates: OrchestratorCandidate[] =
      live.length > 0
        ? [...live]
            .sort(byMostRecent)
            .map<OrchestratorCandidate>((session) => ({ session, mode: "live" }))
        : [...restorable]
            .sort(byMostRecent)
            .map<OrchestratorCandidate>((session) => ({ session, mode: "restore" }));

    if (candidates.length > 0 && orchestratorSessionStrategy === "reuse") {
      const chosen = candidates[0];
      // Multiple candidates → CLI auto-picks the most recent, but the dashboard
      // surfaces all of them via the orchestrator-selection page. Only meaningful
      // when the dashboard is running.
      otherCandidateCount = candidates.length - 1;
      if (opts?.dashboard !== false && candidates.length > 1) {
        hasMultipleReusable = true;
      }

      const otherSuffix =
        otherCandidateCount > 0 ? ` (${otherCandidateCount} other session(s) available)` : "";

      if (chosen.mode === "live") {
        selectedOrchestratorId = chosen.session.id;
        spinner.succeed(`Using existing orchestrator session: ${chosen.session.id}${otherSuffix}`);
      } else {
        try {
          spinner.start(`Restoring orchestrator session: ${chosen.session.id}`);
          const restoredSession = await sm.restore(chosen.session.id);
          selectedOrchestratorId = restoredSession.id;
          restored = true;
          spinner.succeed(
            `Restored orchestrator session: ${restoredSession.id}${otherSuffix}`,
          );
        } catch (err) {
          spinner.fail(`Failed to restore orchestrator session: ${chosen.session.id}`);
          if (dashboardProcess) {
            dashboardProcess.kill();
          }
          throw new Error(
            `Failed to restore orchestrator session ${chosen.session.id}: ${
              err instanceof Error ? err.message : String(err)
            }`,
            { cause: err },
          );
        }
      }
    } else {
      if (orchestratorSessionStrategy === "delete") {
        const liveOrchestrators = orchestrators.filter((s) => !isTerminalSession(s));
        for (const orchestrator of liveOrchestrators) {
          try {
            await sm.kill(orchestrator.id);
          } catch (err) {
            spinner.fail(`Failed to replace existing orchestrator: ${orchestrator.id}`);
            if (dashboardProcess) {
              dashboardProcess.kill();
            }
            throw new Error(
              `Failed to kill existing orchestrator ${orchestrator.id}: ${
                err instanceof Error ? err.message : String(err)
              }`,
              { cause: err },
            );
          }
        }
      }

      // No reusable orchestrators — spawn a fresh numbered one.
      try {
        spinner.start("Creating orchestrator session");
        const systemPrompt = generateOrchestratorPrompt({ config, projectId, project });
        const session = await sm.spawnOrchestrator({ projectId, systemPrompt });
        selectedOrchestratorId = session.id;
        reused =
          orchestratorSessionStrategy === "reuse" &&
          session.metadata?.["orchestratorSessionReused"] === "true";
        spinner.succeed(reused ? "Orchestrator session reused" : "Orchestrator session created");
      } catch (err) {
        spinner.fail("Orchestrator setup failed");
        if (dashboardProcess) {
          dashboardProcess.kill();
        }
        throw new Error(
          `Failed to setup orchestrator: ${err instanceof Error ? err.message : String(err)}`,
          { cause: err },
        );
      }
    }
  }

  // Print summary
  console.log(chalk.bold.green("\n✓ Startup complete\n"));

  if (opts?.dashboard !== false) {
    console.log(chalk.cyan("Dashboard:"), `http://localhost:${port}`);
  }

  if (shouldStartLifecycle && lifecycleStatus) {
    const lifecycleLabel = lifecycleStatus.started ? "started" : "already running";
    console.log(chalk.cyan("Lifecycle:"), lifecycleLabel);
  }

  if (opts?.orchestrator !== false && selectedOrchestratorId) {
    const restoreNote = restored ? " (restored)" : "";
    const otherSummarySuffix =
      otherCandidateCount > 0 ? ` — ${otherCandidateCount} other session(s) available` : "";
    const target =
      opts?.dashboard !== false
        ? projectSessionUrl(port, projectId, selectedOrchestratorId)
        : `ao session attach ${selectedOrchestratorId}`;

    if (reused) {
      console.log(
        chalk.cyan("Orchestrator:"),
        `reused existing session (${selectedOrchestratorId})${otherSummarySuffix}`,
      );
    } else {
      console.log(
        chalk.cyan("Orchestrator:"),
        `${target}${restoreNote}${otherSummarySuffix}`,
      );
    }
  }

  console.log(chalk.dim(`Config: ${config.configPath}`));

  // Auto-open browser once the server is ready.
  // With a single chosen orchestrator (live, restored, or newly spawned), navigate directly to
  // its session page. With multiple reusable orchestrators, open the selection page so the user
  // can choose or spawn a new one — the dashboard only links one orchestrator per project.
  // Polls the port instead of using a fixed delay — deterministic and works regardless of
  // how long Next.js takes to compile. AbortController cancels polling on early exit.
  let openAbort: AbortController | undefined;
  if (opts?.dashboard !== false) {
    openAbort = new AbortController();
    const orchestratorUrl = hasMultipleReusable
      ? `http://localhost:${port}/orchestrators?project=${projectId}`
      : selectedOrchestratorId
        ? projectSessionUrl(port, projectId, selectedOrchestratorId)
        : `http://localhost:${port}`;
    void waitForPortAndOpen(port, orchestratorUrl, openAbort.signal);
  }

  // Keep dashboard process alive if it was started
  if (dashboardProcess) {
    // Kill the dashboard child when the parent exits for any reason
    // (Ctrl+C, SIGTERM from `ao stop`, normal exit, etc.).
    // We use the `exit` event instead of SIGINT/SIGTERM to avoid
    // conflicting with the shutdown handler in registerStart that
    // flushes lifecycle state and calls process.exit() with the
    // correct exit code (130 for SIGINT, 0 for SIGTERM).
    /* c8 ignore start -- exit handler only fires on process termination */
    const killDashboardChild = (): void => {
      try {
        dashboardProcess?.kill("SIGTERM");
      } catch {
        // already dead
      }
    };
    /* c8 ignore stop */
    process.on("exit", killDashboardChild);

    dashboardProcess.on("exit", (code) => {
      process.removeListener("exit", killDashboardChild);
      if (openAbort) openAbort.abort();
      if (code !== 0 && code !== null) {
        console.error(chalk.red(`Dashboard exited with code ${code}`));
      }
      process.exit(code ?? 0);
    });
  }

  return port;
}
