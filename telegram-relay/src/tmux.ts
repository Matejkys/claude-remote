import { execFile } from "child_process";
import { promisify } from "util";
import Convert from "ansi-to-html";
import sharp from "sharp";

const execFileAsync = promisify(execFile);

// ANSI-to-HTML converter for screenshot rendering
const ansiConverter = new Convert({
  fg: "#D4D4D4",
  bg: "#1E1E1E",
  newline: true,
  escapeXML: true,
});

// Terminal rendering configuration
const TERMINAL_FONT_SIZE = 14;
const TERMINAL_LINE_HEIGHT = 18;
const TERMINAL_PADDING = 20;
const TERMINAL_CHAR_WIDTH = 8.4;
const TERMINAL_WIDTH_CHARS = 120;

/**
 * Known Claude Code prompt patterns that indicate the terminal is waiting for user input.
 * Each pattern has a regex and a human-readable label for identification.
 */
const WAITING_PATTERNS: Array<{ pattern: RegExp; label: string }> = [
  // Permission prompts
  { pattern: /Allow once/i, label: "permission-prompt" },
  { pattern: /Allow always/i, label: "permission-prompt" },
  { pattern: /\bDeny\b/, label: "permission-prompt" },
  { pattern: /Do you want to proceed/i, label: "confirmation-prompt" },
  { pattern: /\(y\/n\)/i, label: "yes-no-prompt" },
  { pattern: /\[Y\/n\]/i, label: "yes-no-prompt" },
  { pattern: /\[y\/N\]/i, label: "yes-no-prompt" },
  { pattern: /approve/i, label: "approval-prompt" },

  // Claude Code specific tool approval patterns
  { pattern: /Yes\s*,?\s*allow\s+this/i, label: "permission-prompt" },
  { pattern: /No\s*,?\s*deny\s+this/i, label: "permission-prompt" },

  // Input / question prompts from Claude Code
  { pattern: /\?\s*$/, label: "question-prompt" },
  { pattern: /^\s*\d+\.\s+.+/m, label: "numbered-options" },

  // Elicitation / AskUserQuestion
  { pattern: /Enter your (choice|answer|response)/i, label: "input-prompt" },
  { pattern: /Type your (message|response|answer)/i, label: "input-prompt" },
  { pattern: /Please (choose|select|enter|type|provide)/i, label: "input-prompt" },
];

/**
 * Patterns that indicate the terminal is idle (CC finished, shell prompt visible).
 */
const IDLE_PATTERNS: Array<{ pattern: RegExp; label: string }> = [
  // Shell prompts - CC is done, user can type a new command
  { pattern: /\$\s*$/, label: "shell-prompt" },
  { pattern: />\s*$/, label: "shell-prompt" },
  { pattern: /❯\s*$/, label: "shell-prompt" },
  { pattern: /➜\s*$/, label: "shell-prompt" },
];

/**
 * Result of checking whether a pane is waiting for input.
 */
export interface PaneStatus {
  paneId: string;
  isWaiting: boolean;
  isIdle: boolean;
  matchedPattern: string | null;
  lastLines: string;
}

/**
 * Sends keystrokes to a specific tmux pane.
 * Uses -l (literal) flag to send text character-by-character without interpretation.
 * Then sends Enter separately to submit.
 */
export async function sendKeys(paneId: string, text: string): Promise<void> {
  // Send text literally (no shell interpretation)
  await execFileAsync("tmux", [
    "send-keys",
    "-t",
    paneId,
    "-l",
    text,
  ]);

  // Send Enter to submit
  await execFileAsync("tmux", [
    "send-keys",
    "-t",
    paneId,
    "Enter",
  ]);
}

/**
 * Captures the visible content of a tmux pane.
 * @param paneId - The tmux pane identifier (e.g., "%0")
 * @param lines - Number of lines to capture from the bottom (default: 50)
 * @returns The captured text content
 */
export async function capturePane(
  paneId: string,
  lines: number = 50
): Promise<string> {
  const { stdout } = await execFileAsync("tmux", [
    "capture-pane",
    "-t",
    paneId,
    "-p",
    "-S",
    `-${lines}`,
  ]);
  return stdout;
}

/**
 * Checks if a tmux pane is waiting for user input by analyzing the last few lines
 * of terminal output against known Claude Code prompt patterns.
 */
export async function isWaitingForInput(paneId: string): Promise<PaneStatus> {
  const captured = await capturePane(paneId, 20);

  // Trim trailing whitespace/empty lines, then check last meaningful lines
  const lines = captured.split("\n");
  const nonEmptyLines = lines.filter((line) => line.trim().length > 0);
  const lastLines = nonEmptyLines.slice(-10).join("\n");

  // Check for waiting patterns
  for (const { pattern, label } of WAITING_PATTERNS) {
    if (pattern.test(lastLines)) {
      return {
        paneId,
        isWaiting: true,
        isIdle: false,
        matchedPattern: label,
        lastLines,
      };
    }
  }

  // Check for idle patterns (shell prompt visible = CC is done)
  for (const { pattern, label } of IDLE_PATTERNS) {
    if (pattern.test(lastLines)) {
      return {
        paneId,
        isWaiting: false,
        isIdle: true,
        matchedPattern: label,
        lastLines,
      };
    }
  }

  // No recognized pattern - assume not waiting
  return {
    paneId,
    isWaiting: false,
    isIdle: false,
    matchedPattern: null,
    lastLines,
  };
}

/**
 * Checks if a tmux session exists and is active.
 */
export async function isSessionActive(session: string): Promise<boolean> {
  try {
    await execFileAsync("tmux", ["has-session", "-t", session]);
    return true;
  } catch {
    return false;
  }
}

/**
 * Lists all pane IDs in a tmux session.
 * @returns Array of pane identifiers (e.g., ["%0", "%1", "%2"])
 */
export async function listPanes(session: string): Promise<string[]> {
  try {
    const { stdout } = await execFileAsync("tmux", [
      "list-panes",
      "-t",
      session,
      "-F",
      "#{pane_id}",
    ]);
    return stdout
      .trim()
      .split("\n")
      .filter((id) => id.length > 0);
  } catch {
    return [];
  }
}

/**
 * Lists all active tmux sessions.
 * @returns Raw output from tmux list-sessions
 */
export async function listSessions(): Promise<string> {
  try {
    const { stdout } = await execFileAsync("tmux", ["list-sessions"]);
    return stdout.trim();
  } catch {
    return "No active tmux sessions found.";
  }
}

/**
 * Session info returned by listSessionsByPrefix.
 */
export interface SessionInfo {
  name: string;
  windows: number;
  created: string;
}

/**
 * Lists tmux sessions whose names start with the given prefix.
 * @returns Array of matching session info objects
 */
export async function listSessionsByPrefix(prefix: string): Promise<SessionInfo[]> {
  try {
    const { stdout } = await execFileAsync("tmux", [
      "list-sessions",
      "-F",
      "#{session_name}\t#{session_windows}\t#{session_created_string}",
    ]);
    return stdout
      .trim()
      .split("\n")
      .filter((line) => line.length > 0)
      .map((line) => {
        const [name, windows, created] = line.split("\t");
        return { name, windows: Number(windows) || 1, created: created || "" };
      })
      .filter((s) => s.name.startsWith(prefix));
  } catch {
    return [];
  }
}

/**
 * Lists all pane IDs across all sessions matching the given prefix.
 * Returns panes tagged with their session name and project name for disambiguation.
 */
export async function listAllPanesForPrefix(
  prefix: string
): Promise<Array<{ sessionName: string; paneId: string; projectName?: string }>> {
  const sessions = await listSessionsByPrefix(prefix);
  const results: Array<{ sessionName: string; paneId: string; projectName?: string }> = [];

  for (const session of sessions) {
    const panes = await listPanes(session.name);
    for (const paneId of panes) {
      // Get project name from pane's working directory
      const projectName = await getPaneProjectName(paneId);
      results.push({ sessionName: session.name, paneId, projectName });
    }
  }

  return results;
}

/**
 * Gets the project name (last directory in path) for a tmux pane.
 */
async function getPaneProjectName(paneId: string): Promise<string | undefined> {
  try {
    const { stdout } = await execFileAsync("tmux", [
      "display-message",
      "-t",
      paneId,
      "-p",
      "#{pane_current_path}",
    ]);
    const workingDir = stdout.trim();
    if (workingDir) {
      const parts = workingDir.split("/");
      return parts[parts.length - 1] || undefined;
    }
  } catch {
    return undefined;
  }
  return undefined;
}

/**
 * Captures terminal content from a tmux pane and renders it as a PNG image.
 * Uses ANSI-to-HTML conversion, then wraps in SVG foreignObject for rendering with Sharp.
 * @param paneId - The tmux pane identifier
 * @returns PNG image as a Buffer
 */
export async function capturePaneAsImage(paneId: string): Promise<Buffer> {
  const captured = await capturePane(paneId, 50);

  // Convert ANSI escape codes to HTML spans with inline color styles
  const htmlContent = ansiConverter.toHtml(captured);

  // Calculate image dimensions based on content
  const lineCount = captured.split("\n").length;
  const imageWidth =
    TERMINAL_CHAR_WIDTH * TERMINAL_WIDTH_CHARS + TERMINAL_PADDING * 2;
  const imageHeight =
    lineCount * TERMINAL_LINE_HEIGHT + TERMINAL_PADDING * 2;

  // Build SVG with foreignObject for HTML rendering
  // Sharp can render SVG to PNG, and foreignObject allows embedding HTML
  const svg = `<svg width="${imageWidth}" height="${imageHeight}" xmlns="http://www.w3.org/2000/svg">
  <rect width="100%" height="100%" fill="#1E1E1E" rx="8"/>
  <foreignObject width="100%" height="100%">
    <div xmlns="http://www.w3.org/1999/xhtml" style="
      font-family: 'Menlo', 'Monaco', 'Courier New', monospace;
      font-size: ${TERMINAL_FONT_SIZE}px;
      line-height: ${TERMINAL_LINE_HEIGHT}px;
      color: #D4D4D4;
      background: #1E1E1E;
      padding: ${TERMINAL_PADDING}px;
      white-space: pre;
      overflow: hidden;
    ">${htmlContent}</div>
  </foreignObject>
</svg>`;

  const pngBuffer = await sharp(Buffer.from(svg)).png().toBuffer();
  return pngBuffer;
}
