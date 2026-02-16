import { config as loadDotenv } from "dotenv";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";

// Load .env from project root (claude-remote/.env)
const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(__dirname, "..", "..");
const ENV_PATH = resolve(PROJECT_ROOT, ".env");

loadDotenv({ path: ENV_PATH });

// Required environment variables - fail fast if missing
const REQUIRED_VARS = [
  "TELEGRAM_BOT_TOKEN",
  "TELEGRAM_USER_ID",
] as const;

const missing = REQUIRED_VARS.filter((key) => !process.env[key]);
if (missing.length > 0) {
  console.error(
    `[config] Missing required environment variables: ${missing.join(", ")}`
  );
  console.error(`[config] Expected .env file at: ${ENV_PATH}`);
  console.error(
    `[config] Create the .env file with the following variables:`
  );
  for (const key of missing) {
    console.error(`  ${key}=<value>`);
  }
  process.exit(1);
}

export const config = {
  /** Telegram Bot API token from @BotFather */
  telegramBotToken: process.env.TELEGRAM_BOT_TOKEN!,

  /** Numeric Telegram user ID for whitelist authentication */
  telegramUserId: Number(process.env.TELEGRAM_USER_ID!),

  /** Prefix for tmux session names to monitor (e.g. "claude-" matches claude-164549, claude-091200) */
  tmuxSessionPrefix: process.env.TMUX_SESSION_PREFIX || "claude-",

  /** Optional shared secret for future HTTP API authentication */
  httpSecret: process.env.HTTP_SECRET || undefined,

  /** Path to the project root directory */
  projectRoot: PROJECT_ROOT,

  /** Path to the .env file */
  envPath: ENV_PATH,
} as const;

// Validate TELEGRAM_USER_ID is a valid number
if (isNaN(config.telegramUserId) || config.telegramUserId <= 0) {
  console.error(
    `[config] TELEGRAM_USER_ID must be a positive number, got: "${process.env.TELEGRAM_USER_ID}"`
  );
  process.exit(1);
}
