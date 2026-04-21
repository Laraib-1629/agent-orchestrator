"use client";

import { useEffect, useMemo, useRef, useState, type RefObject } from "react";
import { useTheme } from "next-themes";

// Import xterm CSS (must be imported in client component)
import "@xterm/xterm/css/xterm.css";

// Static type-only imports (erased at compile time, no SSR impact).
// The runtime Terminal class is loaded via dynamic import() inside useEffect to avoid SSR.
import type { Terminal as TerminalType } from "@xterm/xterm";
import type { FitAddon as FitAddonType } from "@xterm/addon-fit";

import { useMux } from "@/hooks/useMux";
import { attachTouchScroll } from "@/lib/terminal-touch-scroll";

import { registerClipboardHandlers } from "./terminal-clipboard";
import { FONT_SIZE_KEY, resolveMonoFontFamily } from "./terminal-font";
import { buildTerminalThemes, type TerminalVariant } from "./terminal-themes";

export interface UseXtermTerminalOptions {
  appearance: "theme" | "dark";
  variant: TerminalVariant;
  fontSize: number;
  autoFocus: boolean;
}

export interface UseXtermTerminalResult {
  error: string | null;
  followOutput: boolean;
  scrollToLatest: () => void;
  muxStatus: ReturnType<typeof useMux>["status"];
  terminalInstance: RefObject<TerminalType | null>;
  fitAddon: RefObject<FitAddonType | null>;
}

/**
 * Owns the xterm.js instance and its wiring to the multiplexed WebSocket.
 *
 * Registers the XDA handler that tmux looks for to enable clipboard (OSC 52),
 * buffers writes while a selection is active, preserves scrollback position
 * for "follow output" behaviour, and tears everything down on unmount.
 */
export function useXtermTerminal(
  terminalRef: RefObject<HTMLDivElement | null>,
  sessionId: string,
  options: UseXtermTerminalOptions,
): UseXtermTerminalResult {
  const { appearance, variant, fontSize, autoFocus } = options;
  const { resolvedTheme } = useTheme();
  const terminalThemes = useMemo(() => buildTerminalThemes(variant), [variant]);
  const {
    subscribeTerminal,
    writeTerminal,
    resizeTerminal: resizeTerminalMux,
    openTerminal,
    closeTerminal,
    status: muxStatus,
  } = useMux();

  const terminalInstance = useRef<TerminalType | null>(null);
  const fitAddon = useRef<FitAddonType | null>(null);
  const [error, setError] = useState<string | null>(null);
  const followOutputRef = useRef(true);
  const [followOutput, setFollowOutput] = useState(true);

  useEffect(() => {
    if (!terminalRef.current) return;

    // Dynamically import xterm.js to avoid SSR issues
    let mounted = true;
    let cleanup: (() => void) | null = null;
    let inputDisposable: { dispose(): void } | null = null;
    let unsubscribe: (() => void) | null = null;

    Promise.all([
      import("@xterm/xterm").then((mod) => mod.Terminal),
      import("@xterm/addon-fit").then((mod) => mod.FitAddon),
      import("@xterm/addon-web-links").then((mod) => mod.WebLinksAddon),
      document.fonts.ready,
    ])
      .then(([Terminal, FitAddon, WebLinksAddon]) => {
        if (!mounted || !terminalRef.current) return;

        const isDark = appearance === "dark" || resolvedTheme !== "light";
        const activeTheme = isDark ? terminalThemes.dark : terminalThemes.light;

        // NOTE: xterm's internal char-size measurement uses canvas ctx.font which
        // cannot resolve `var(...)`. resolveMonoFontFamily() reads the CSS custom
        // property at runtime so we still honour the app's configured font token
        // (next/font generated name) while handing xterm a concrete string.
        const terminal = new Terminal({
          cursorBlink: true,
          fontSize: fontSize,
          fontFamily: resolveMonoFontFamily(),
          // xterm v6 default lineHeight (1.0) collides rows with JetBrains Mono's
          // tall x-height. 1.2 restores visual breathing room between lines.
          lineHeight: 1.2,
          theme: activeTheme,
          // Light mode needs an explicit contrast floor because agent UIs often emit
          // dim/faint ANSI sequences that become unreadable on a near-white background.
          minimumContrastRatio: isDark ? 1 : 7,
          scrollback: 10000,
          allowProposedApi: true,
          fastScrollSensitivity: 3,
          scrollSensitivity: 1,
        });

        const fit = new FitAddon();
        terminal.loadAddon(fit);
        fitAddon.current = fit;

        const webLinks = new WebLinksAddon();
        terminal.loadAddon(webLinks);

        registerClipboardHandlers(terminal);

        terminal.open(terminalRef.current);
        terminalInstance.current = terminal;

        if (autoFocus) {
          terminal.focus();
        }

        fit.fit();

        // Deferred fit for containers that weren't sized yet on first paint.
        const deferredFitTimeout = setTimeout(() => {
          if (mounted && fitAddon.current) {
            try {
              fitAddon.current.fit();
              resizeTerminalMux(sessionId, terminal.cols, terminal.rows);
            } catch {
              // Ignore fit errors
            }
          }
        }, 100);

        // next/font uses font-display:swap, so document.fonts.ready can resolve
        // before JetBrains Mono actually swaps in. Without this listener,
        // xterm's cell measurement stays pinned to the fallback font and cells
        // look wide once the real font swaps. 'loadingdone' forces a re-fit.
        const handleFontsLoadingDone = () => {
          if (!mounted || !fitAddon.current || !terminalInstance.current) return;
          try {
            terminalInstance.current.options.fontFamily = resolveMonoFontFamily();
            terminalInstance.current.clearTextureAtlas?.();
            fitAddon.current.fit();
            resizeTerminalMux(sessionId, terminalInstance.current.cols, terminalInstance.current.rows);
          } catch {
            // Ignore fit errors
          }
        };
        // Feature-detect addEventListener — jsdom's document.fonts mock lacks it.
        const fontsFace =
          typeof document !== "undefined" ? document.fonts : undefined;
        const fontsListenerAttached =
          !!fontsFace && typeof fontsFace.addEventListener === "function";
        if (fontsListenerAttached) {
          fontsFace!.addEventListener("loadingdone", handleFontsLoadingDone);
        }

        const viewport = terminal.element?.querySelector<HTMLElement>(".xterm-viewport") ?? null;

        // Touch scroll on mobile — disables follow-output while user scrolls.
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const cleanupTouchScroll = attachTouchScroll(terminal as any, (data) => {
          writeTerminal(sessionId, data);
        }, {
          onScrollAway: () => { followOutputRef.current = false; setFollowOutput(false); },
          onScrollTowardLatest: () => { followOutputRef.current = true; setFollowOutput(true); },
        });

        let resizeObserver: ResizeObserver | null = null;
        if (terminalRef.current) {
          resizeObserver = new ResizeObserver(() => {
            if (mounted && fitAddon.current) {
              try {
                fitAddon.current.fit();
                resizeTerminalMux(sessionId, terminal.cols, terminal.rows);
              } catch {
                // Ignore fit errors
              }
            }
          });
          resizeObserver.observe(terminalRef.current);
        }

        // ── Preserve selection while terminal receives output ────────
        // xterm.js clears selection on every terminal.write(). We buffer
        // incoming data while a selection is active so the highlight stays
        // visible for Cmd+C. Flushed when selection clears or buffer caps.
        const writeBuffer: string[] = [];
        let selectionActive = false;
        let safetyTimer: ReturnType<typeof setTimeout> | null = null;
        let bufferBytes = 0;
        const MAX_BUFFER_BYTES = 1_048_576; // 1 MB

        const flushWriteBuffer = () => {
          if (safetyTimer) {
            clearTimeout(safetyTimer);
            safetyTimer = null;
          }
          if (writeBuffer.length > 0) {
            terminal.write(writeBuffer.join(""));
            writeBuffer.length = 0;
            bufferBytes = 0;
          }
        };

        const selectionDisposable = terminal.onSelectionChange(() => {
          if (terminal.hasSelection()) {
            selectionActive = true;
            if (!safetyTimer) {
              safetyTimer = setTimeout(() => {
                selectionActive = false;
                flushWriteBuffer();
              }, 5_000);
            }
          } else {
            selectionActive = false;
            flushWriteBuffer();
          }
        });

        openTerminal(sessionId);

        unsubscribe = subscribeTerminal(sessionId, (data) => {
          if (selectionActive) {
            writeBuffer.push(data);
            bufferBytes += data.length;
            if (bufferBytes > MAX_BUFFER_BYTES) {
              selectionActive = false;
              flushWriteBuffer();
            }
          } else {
            terminal.write(data);
            if (followOutputRef.current && viewport) {
              programmaticScroll = true;
              viewport.scrollTop = viewport.scrollHeight;
            }
          }
        });

        let programmaticScroll = false;
        const handleViewportScroll = () => {
          if (!viewport) return;
          if (programmaticScroll) {
            programmaticScroll = false;
            return;
          }
          const distFromBottom = viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight;
          if (distFromBottom < 24) {
            followOutputRef.current = true;
            setFollowOutput(true);
          } else {
            followOutputRef.current = false;
            setFollowOutput(false);
          }
        };
        viewport?.addEventListener("scroll", handleViewportScroll, { passive: true });

        const handleResize = () => {
          if (fit) {
            fit.fit();
            resizeTerminalMux(sessionId, terminal.cols, terminal.rows);
          }
        };
        window.addEventListener("resize", handleResize);

        inputDisposable = terminal.onData((data) => {
          writeTerminal(sessionId, data);
        });

        resizeTerminalMux(sessionId, terminal.cols, terminal.rows);

        cleanup = () => {
          clearTimeout(deferredFitTimeout);
          resizeObserver?.disconnect();
          cleanupTouchScroll();
          selectionDisposable.dispose();
          if (safetyTimer) clearTimeout(safetyTimer);
          window.removeEventListener("resize", handleResize);
          if (fontsListenerAttached && fontsFace) {
            fontsFace.removeEventListener("loadingdone", handleFontsLoadingDone);
          }
          viewport?.removeEventListener("scroll", handleViewportScroll);
          inputDisposable?.dispose();
          inputDisposable = null;
          unsubscribe?.();
          closeTerminal(sessionId);
          terminal.dispose();
        };
      })
      .catch((err) => {
        console.error("[DirectTerminal] Failed to load xterm.js:", err);
        setError("Failed to load terminal");
      });

    return () => {
      mounted = false;
      cleanup?.();
    };
    // fontSize intentionally NOT in deps — it's handled by a dedicated effect
    // below that mutates terminal.options.fontSize in place. Adding it here
    // would tear down and recreate the terminal (and WebSocket) on every
    // stepper click, losing scrollback and flashing content.
  }, [
    appearance,
    sessionId,
    variant,
    resolvedTheme,
    terminalThemes,
    subscribeTerminal,
    writeTerminal,
    resizeTerminalMux,
    openTerminal,
    closeTerminal,
  ]);

  // Re-send terminal dimensions on every reconnect so the server-side PTY
  // matches the client's xterm.js size (new PTYs spawn at 80×24 default).
  useEffect(() => {
    if (muxStatus !== "connected") return;
    const fit = fitAddon.current;
    const terminal = terminalInstance.current;
    if (!fit || !terminal) return;
    fit.fit();
    resizeTerminalMux(sessionId, terminal.cols, terminal.rows);
  }, [muxStatus, sessionId, resizeTerminalMux]);

  // Live theme switching without terminal recreation
  useEffect(() => {
    const terminal = terminalInstance.current;
    if (!terminal) return;
    const isDark = appearance === "dark" || resolvedTheme !== "light";
    terminal.options.theme = isDark ? terminalThemes.dark : terminalThemes.light;
    terminal.options.minimumContrastRatio = isDark ? 1 : 7;
  }, [appearance, resolvedTheme, terminalThemes]);

  // Font size change — mutate in place and persist, then resize the PTY so
  // the shell wraps at the new cols/rows.
  useEffect(() => {
    const terminal = terminalInstance.current;
    const fit = fitAddon.current;
    if (!terminal || !fit) return;
    terminal.options.fontSize = fontSize;
    try {
      localStorage.setItem(FONT_SIZE_KEY, String(fontSize));
    } catch {
      // localStorage might be unavailable
    }
    fit.fit();
    resizeTerminalMux(sessionId, terminal.cols, terminal.rows);
  }, [fontSize, sessionId, resizeTerminalMux]);

  const scrollToLatest = () => {
    followOutputRef.current = true;
    setFollowOutput(true);
    const t = terminalInstance.current;
    if (t) {
      const vp = t.element?.querySelector<HTMLElement>(".xterm-viewport");
      if (vp) vp.scrollTop = vp.scrollHeight;
    }
  };

  return {
    error,
    followOutput,
    scrollToLatest,
    muxStatus,
    terminalInstance,
    fitAddon,
  };
}
