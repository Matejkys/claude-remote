import { Bot, Context, InputFile, InlineKeyboard } from "grammy";
import { config } from "./config.js";
import {
  sendKeys,
  capturePane,
  isWaitingForInput,
  listPanes,
  listSessions,
  listSessionsByPrefix,
  listAllPanesForPrefix,
  capturePaneAsImage,
  PaneStatus,
} from "./tmux.js";

// Maximum length for a single Telegram message
const TELEGRAM_MESSAGE_LIMIT = 4096;

// Temporary storage for messages awaiting pane selection
const pendingMessages = new Map<number, string>();

// Number of lines to capture for /status command
const STATUS_CAPTURE_LINES = 50;

// Initialize the Telegram bot with grammy (long-polling)
const bot = new Bot(config.telegramBotToken);

/**
 * Security middleware: only allow messages from the whitelisted user.
 * Silently ignores messages from all other users.
 */
function isAuthorizedUser(ctx: Context): boolean {
  return ctx.from?.id === config.telegramUserId;
}

/**
 * Sends a text message to the authorized user, splitting into multiple
 * messages if the content exceeds Telegram's 4096 character limit.
 * Uses HTML parse mode for formatting.
 */
async function sendMessage(text: string): Promise<void> {
  const chunks = splitMessage(text, TELEGRAM_MESSAGE_LIMIT);
  for (const chunk of chunks) {
    try {
      await bot.api.sendMessage(config.telegramUserId, chunk, {
        parse_mode: "HTML",
      });
    } catch (error) {
      // If HTML parsing fails, retry without parse mode
      try {
        await bot.api.sendMessage(config.telegramUserId, chunk);
      } catch (retryError) {
        console.error("[bot] Failed to send message:", retryError);
      }
    }
  }
}

/**
 * Splits a long message into chunks that fit within the Telegram message limit.
 * Tries to split on newline boundaries for readability.
 */
function splitMessage(text: string, limit: number): string[] {
  if (text.length <= limit) {
    return [text];
  }

  const chunks: string[] = [];
  let remaining = text;

  while (remaining.length > 0) {
    if (remaining.length <= limit) {
      chunks.push(remaining);
      break;
    }

    // Find the last newline within the limit
    let splitIndex = remaining.lastIndexOf("\n", limit);
    if (splitIndex <= 0) {
      // No good newline break found, force split at limit
      splitIndex = limit;
    }

    chunks.push(remaining.slice(0, splitIndex));
    remaining = remaining.slice(splitIndex + 1);
  }

  return chunks;
}

/**
 * Escapes special characters for Telegram HTML parse mode.
 */
function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

/**
 * Resolves which pane to target for input.
 * Scans all panes across all claude-* tmux sessions.
 */
async function resolveTargetPane(): Promise<
  | { type: "single"; pane: PaneStatus & { sessionName: string } }
  | { type: "none" }
  | { type: "multiple"; panes: Array<PaneStatus & { sessionName: string }> }
> {
  const allPanes = await listAllPanesForPrefix(config.tmuxSessionPrefix);

  if (allPanes.length === 0) {
    return { type: "none" };
  }

  const statusesWithSession = await Promise.all(
    allPanes.map(async (p) => {
      const status = await isWaitingForInput(p.paneId);
      return { ...status, sessionName: p.sessionName };
    })
  );
  const waitingPanes = statusesWithSession.filter((s) => s.isWaiting);

  if (waitingPanes.length === 0) {
    return { type: "none" };
  }

  if (waitingPanes.length === 1) {
    return { type: "single", pane: waitingPanes[0] };
  }

  return { type: "multiple", panes: waitingPanes };
}

/**
 * Sends input to a resolved single pane, or replies with disambiguation info.
 * Returns true if input was sent, false otherwise.
 */
async function sendToWaitingPane(
  ctx: Context,
  text: string
): Promise<boolean> {
  const result = await resolveTargetPane();

  switch (result.type) {
    case "none":
      return false;

    case "single":
      await sendKeys(result.pane.paneId, text);
      await ctx.reply(
        `✓ Response sent to ${result.pane.sessionName} [${result.pane.paneId}]`
      );
      return true;

    case "multiple":
      const paneList = result.panes
        .map(
          (p) =>
            `  ${p.sessionName} [${p.paneId}]`
        )
        .join("\n");
      await ctx.reply(
        `Multiple panes are waiting for input:\n${paneList}\n\nUse /pane <id> <text> to specify which pane.`
      );
      return false;
  }
}

// --- Command Handlers ---

bot.command("y", async (ctx) => {
  if (!isAuthorizedUser(ctx)) return;
  await sendToWaitingPane(ctx, "y");
});

bot.command("yes", async (ctx) => {
  if (!isAuthorizedUser(ctx)) return;
  await sendToWaitingPane(ctx, "y");
});

bot.command("n", async (ctx) => {
  if (!isAuthorizedUser(ctx)) return;
  await sendToWaitingPane(ctx, "n");
});

bot.command("no", async (ctx) => {
  if (!isAuthorizedUser(ctx)) return;
  await sendToWaitingPane(ctx, "n");
});

bot.command("select", async (ctx) => {
  if (!isAuthorizedUser(ctx)) return;

  const selection = ctx.match?.trim();
  if (!selection || isNaN(Number(selection))) {
    await ctx.reply("Usage: /select <number>\nExample: /select 1");
    return;
  }

  await sendToWaitingPane(ctx, selection);
});

bot.command("pane", async (ctx) => {
  if (!isAuthorizedUser(ctx)) return;

  const args = ctx.match?.trim();
  if (!args) {
    await ctx.reply("Usage: /pane <id> <text>\nExample: /pane %0 y");
    return;
  }

  // Parse: first token is pane ID, rest is the text to send
  const spaceIndex = args.indexOf(" ");
  if (spaceIndex === -1) {
    await ctx.reply("Usage: /pane <id> <text>\nExample: /pane %0 y");
    return;
  }

  const paneId = args.slice(0, spaceIndex);
  const text = args.slice(spaceIndex + 1);

  try {
    await sendKeys(paneId, text);
    await ctx.reply(`Sent to pane ${paneId}`);
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Unknown error";
    await ctx.reply(`Failed to send to pane ${paneId}: ${message}`);
  }
});

bot.command("prompt", async (ctx) => {
  if (!isAuthorizedUser(ctx)) return;

  const text = ctx.match?.trim();
  if (!text) {
    await ctx.reply("Usage: /prompt <text>\nExample: /prompt Explain this code");
    return;
  }

  const allPanes = await listAllPanesForPrefix(config.tmuxSessionPrefix);

  if (allPanes.length === 0) {
    await ctx.reply(
      "No claude-* tmux sessions found. Start one with 'cy'."
    );
    return;
  }

  // If single pane, send directly
  if (allPanes.length === 1) {
    try {
      await sendKeys(allPanes[0].paneId, text);
      const label = allPanes[0].projectName || allPanes[0].sessionName;
      await ctx.reply(`✓ Prompt sent to ${label} [${allPanes[0].paneId}]`);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Unknown error";
      await ctx.reply(`✗ Failed to send prompt: ${message}`);
    }
    return;
  }

  // Multiple panes - store message and show inline keyboard
  if (ctx.from?.id) {
    pendingMessages.set(ctx.from.id, text);
  }

  const keyboard = new InlineKeyboard();
  for (const pane of allPanes) {
    const label = pane.projectName
      ? `${pane.projectName} (${pane.sessionName}) [${pane.paneId}]`
      : `${pane.sessionName} [${pane.paneId}]`;
    keyboard.text(label, `select_pane:${pane.paneId}`).row();
  }

  await ctx.reply(
    "Multiple panes found. Choose where to send your prompt:",
    { reply_markup: keyboard }
  );
});

bot.command("status", async (ctx) => {
  if (!isAuthorizedUser(ctx)) return;

  const allPanes = await listAllPanesForPrefix(config.tmuxSessionPrefix);

  if (allPanes.length === 0) {
    await ctx.reply(
      `No claude-* tmux sessions found. Start one with 'cy'.`
    );
    return;
  }

  // Single pane - show status directly
  if (allPanes.length === 1) {
    const { sessionName, paneId, projectName } = allPanes[0];
    try {
      const content = await capturePane(paneId, STATUS_CAPTURE_LINES);
      const escaped = escapeHtml(content);
      const label = projectName || sessionName;
      const header = `<b>${escapeHtml(label)} (${escapeHtml(sessionName)}) [${escapeHtml(paneId)}]:</b>\n`;
      await sendMessage(`${header}<pre>${escaped}</pre>`);
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Unknown error";
      await ctx.reply(`Failed to capture ${sessionName} ${paneId}: ${message}`);
    }
    return;
  }

  // Multiple panes - show inline keyboard for selection
  const keyboard = new InlineKeyboard();
  for (const pane of allPanes) {
    const label = pane.projectName
      ? `${pane.projectName} (${pane.sessionName}) [${pane.paneId}]`
      : `${pane.sessionName} [${pane.paneId}]`;
    keyboard.text(label, `status_pane:${pane.paneId}`).row();
  }
  keyboard.text("All panes", "status_pane:__all__").row();

  await ctx.reply("Select a pane to view status:", {
    reply_markup: keyboard,
  });
});

bot.command("screenshot", async (ctx) => {
  if (!isAuthorizedUser(ctx)) return;

  const allPanes = await listAllPanesForPrefix(config.tmuxSessionPrefix);

  if (allPanes.length === 0) {
    await ctx.reply(
      `No claude-* tmux sessions found. Start one with 'cy'.`
    );
    return;
  }

  for (const { sessionName, paneId } of allPanes) {
    try {
      const imageBuffer = await capturePaneAsImage(paneId);
      const caption = `${sessionName} [${paneId}]`;
      await ctx.replyWithPhoto(new InputFile(imageBuffer, "terminal.png"), {
        caption,
      });
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Unknown error";
      await ctx.reply(
        `Failed to capture screenshot for ${sessionName} ${paneId}: ${message}`
      );
    }
  }
});

bot.command("sessions", async (ctx) => {
  if (!isAuthorizedUser(ctx)) return;

  const sessions = await listSessions();
  const escaped = escapeHtml(sessions);
  await sendMessage(`<b>Active tmux sessions:</b>\n<pre>${escaped}</pre>`);
});

// --- Callback Query Handler (inline keyboard buttons) ---

bot.on("callback_query:data", async (ctx) => {
  if (!isAuthorizedUser(ctx)) return;

  const data = ctx.callbackQuery.data;

  // Handle pane selection for prompt/message
  if (data.startsWith("select_pane:")) {
    const paneId = data.replace("select_pane:", "");
    const userId = ctx.from?.id;

    if (!userId) {
      await ctx.answerCallbackQuery("Error: User ID not found");
      return;
    }

    const text = pendingMessages.get(userId);
    if (!text) {
      await ctx.answerCallbackQuery("Message expired. Please send it again.");
      return;
    }

    // Send the text to selected pane
    try {
      await sendKeys(paneId, text);
      await ctx.answerCallbackQuery("✓ Message sent!");
      await ctx.editMessageText(`✓ Sent to pane ${paneId}:\n"${text}"`);
      pendingMessages.delete(userId);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Unknown error";
      await ctx.answerCallbackQuery(`✗ Failed: ${message}`);
    }
    return;
  }

  // Handle pane selection for /status command
  if (data.startsWith("status_pane:")) {
    const paneId = data.replace("status_pane:", "");
    await ctx.answerCallbackQuery();

    // Show all panes
    if (paneId === "__all__") {
      const allPanes = await listAllPanesForPrefix(config.tmuxSessionPrefix);
      for (const { sessionName, paneId: pid, projectName } of allPanes) {
        try {
          const content = await capturePane(pid, STATUS_CAPTURE_LINES);
          const escaped = escapeHtml(content);
          const label = projectName || sessionName;
          const header = `<b>${escapeHtml(label)} (${escapeHtml(sessionName)}) [${escapeHtml(pid)}]:</b>\n`;
          await sendMessage(`${header}<pre>${escaped}</pre>`);
        } catch (error) {
          const message = error instanceof Error ? error.message : "Unknown error";
          await sendMessage(`Failed to capture ${sessionName} ${pid}: ${message}`);
        }
      }
      try { await ctx.deleteMessage(); } catch { /* ignore */ }
      return;
    }

    // Show single selected pane
    try {
      const allPanes = await listAllPanesForPrefix(config.tmuxSessionPrefix);
      const pane = allPanes.find((p) => p.paneId === paneId);
      const content = await capturePane(paneId, STATUS_CAPTURE_LINES);
      const escaped = escapeHtml(content);
      const label = pane?.projectName || pane?.sessionName || paneId;
      const sessionName = pane?.sessionName || "";
      const header = `<b>${escapeHtml(label)} (${escapeHtml(sessionName)}) [${escapeHtml(paneId)}]:</b>\n`;
      await sendMessage(`${header}<pre>${escaped}</pre>`);
      try { await ctx.deleteMessage(); } catch { /* ignore */ }
    } catch (error) {
      const message = error instanceof Error ? error.message : "Unknown error";
      await sendMessage(`Failed to capture pane ${paneId}: ${message}`);
    }
    return;
  }

  await ctx.answerCallbackQuery("Unknown action");
});

// --- Free text handler ---
// Catches all non-command text messages and sends them intelligently:
// - If CC is waiting for input (permission, question) → answer the prompt
// - If CC is idle (shell prompt) → send as new prompt

bot.on("message:text", async (ctx) => {
  if (!isAuthorizedUser(ctx)) return;

  const text = ctx.message.text;

  // Skip if it looks like an unrecognized command
  if (text.startsWith("/")) {
    await ctx.reply(
      "Unknown command. Available commands:\n" +
        "/y or /yes - approve permission\n" +
        "/n or /no - deny permission\n" +
        "/select <N> - select numbered option\n" +
        "/prompt <text> - send new prompt to Claude\n" +
        "/pane <id> <text> - send to specific pane\n" +
        "/status - view terminal output\n" +
        "/screenshot - terminal as image\n" +
        "/sessions - list tmux sessions"
    );
    return;
  }

  // Try sending to waiting pane first (for permission/question prompts)
  const sent = await sendToWaitingPane(ctx, text);

  // If no waiting pane, send as new prompt to any available pane
  if (!sent) {
    const allPanes = await listAllPanesForPrefix(config.tmuxSessionPrefix);

    if (allPanes.length === 0) {
      await ctx.reply(
        "No claude-* tmux sessions found. Start one with 'cy'."
      );
      return;
    }

    // If single pane, send directly
    if (allPanes.length === 1) {
      try {
        await sendKeys(allPanes[0].paneId, text);
        const label = allPanes[0].projectName || allPanes[0].sessionName;
        await ctx.reply(`✓ Prompt sent to ${label} [${allPanes[0].paneId}]`);
      } catch (error) {
        const message = error instanceof Error ? error.message : "Unknown error";
        await ctx.reply(`✗ Failed to send: ${message}`);
      }
      return;
    }

    // Multiple panes - store message and show inline keyboard
    if (ctx.from?.id) {
      pendingMessages.set(ctx.from.id, text);
    }

    const keyboard = new InlineKeyboard();
    for (const pane of allPanes) {
      const label = pane.projectName
        ? `${pane.projectName} (${pane.sessionName}) [${pane.paneId}]`
        : `${pane.sessionName} [${pane.paneId}]`;
      keyboard.text(label, `select_pane:${pane.paneId}`).row();
    }

    await ctx.reply(
      "Multiple panes found. Choose where to send your message:",
      { reply_markup: keyboard }
    );
  }
});

// --- Startup ---

async function start(): Promise<void> {
  console.log("[bot] Starting Claude Remote Telegram Relay...");
  console.log(`[bot] Session prefix: ${config.tmuxSessionPrefix}`);
  console.log(`[bot] Telegram user ID: ${config.telegramUserId}`);

  // Discover existing claude-* sessions on startup
  const sessions = await listSessionsByPrefix(config.tmuxSessionPrefix);
  if (sessions.length === 0) {
    console.warn(
      `[bot] No tmux sessions matching "${config.tmuxSessionPrefix}*" found. ` +
        `The relay will still start and discover sessions dynamically.`
    );
  } else {
    console.log(
      `[bot] Found ${sessions.length} session(s): ${sessions.map((s) => s.name).join(", ")}`
    );
  }

  // Start the bot with long-polling
  bot.start({
    onStart: async () => {
      console.log("[bot] Telegram bot is running (long-polling)");

      const statusText =
        sessions.length > 0
          ? `Found ${sessions.length} session(s): ${sessions.map((s) => s.name).join(", ")}`
          : `No claude-* sessions found yet. Start one with 'cy'.`;

      await sendMessage(
        `<b>Claude Remote Relay started</b>\n${escapeHtml(statusText)}\n\nReady to relay commands.`
      );
    },
  });
}

// Handle graceful shutdown
function setupShutdownHandlers(): void {
  const shutdown = async (signal: string) => {
    console.log(`[bot] Received ${signal}, shutting down...`);
    try {
      await sendMessage("<b>Claude Remote Relay stopped</b>");
    } catch {
      // Ignore errors during shutdown notification
    }
    bot.stop();
    process.exit(0);
  };

  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

// Handle unhandled errors
bot.catch((err) => {
  console.error("[bot] Unhandled error in bot:", err);
});

setupShutdownHandlers();
start().catch((error) => {
  console.error("[bot] Fatal startup error:", error);
  process.exit(1);
});
