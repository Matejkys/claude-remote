# Claude Remote

macOS menu bar app + Telegram relay for controlling [Claude Code](https://docs.anthropic.com/en/docs/claude-code) remotely from your phone.

When Claude Code needs your attention (permission prompt, question, task completion) and you're away from your Mac, notifications are routed to Telegram where you can respond directly.

## How it works

```
                                        ┌─ Present → macOS notification
CC hook → notify-hook.sh → SwiftUI app ─┤
                                        └─ Away → Telegram → iPhone push
                                                    ↑
iPhone Telegram → Node.js relay → tmux send-keys → CC gets input
```

**Presence detection** uses three signals:
- IOKit HIDIdleTime (keyboard/mouse inactivity)
- Screen lock/unlock events
- Display sleep/wake events

When you're at your Mac, you get native macOS notifications with working Approve/Deny buttons. When you're away, notifications go to Telegram with full terminal context, and you can reply to approve/deny permissions, answer questions, or send any input back to Claude Code.

## Components

| Component | Tech | Purpose |
|-----------|------|---------|
| **ClaudeRemote** | SwiftUI (macOS 14+) | Menu bar app + standalone window — session management, presence detection, notification routing |
| **telegram-relay** | Node.js + TypeScript | Telegram bot — long-polling, tmux interaction, command handling |
| **notify-hook.sh** | Bash | Claude Code hook — enriches notifications with tmux context |

## Features

### Session Manager
- **Live session list** with state detection (Active, Waiting for Input, Idle)
- **Color-coded indicators** — blue (active), orange (waiting), gray (idle)
- **Project name detection** — resolves via git root, falls back to working directory
- **Quick actions** from menu bar: copy attach command, kill session, open in app
- **Full app window** with sidebar + detail panel:
  - Live terminal preview with auto-refresh
  - Send input directly to Claude Code sessions
  - Quick action buttons (Approve/Deny, numbered selections)
  - Rename and kill sessions with confirmation
  - Session info (project, working dir, panes, created time)

### Notification Routing
- **Approve/Deny buttons** on macOS notifications actually send responses to Claude Code
- **Telegram forwarding** with markdown-to-HTML conversion for properly formatted messages
- **Duplicate suppression** — "waiting for input" notifications are suppressed after a "finished" event
- **Presence-based routing** — automatic or manual mode

### Remote Control (Telegram)
- Approve/deny permissions, answer questions, send prompts
- View terminal output and screenshots
- Multi-session support with pane disambiguation
- Claude's markdown output rendered as formatted Telegram HTML (bold, italic, code, code blocks)

## Prerequisites

- macOS 14.0+ (Sonoma)
- [Homebrew](https://brew.sh)
- Node.js 18+
- tmux (`brew install tmux`)
- A Telegram account

## Installation

### 1. Clone and build

```bash
git clone https://github.com/Matejkys/claude-remote.git
cd claude-remote

# Build and install the macOS menu bar app
cd ClaudeRemote
make install
# You'll be prompted for your macOS password to set up keychain access
# This prevents the app from asking for keychain permission on every launch
cd ..

# Install Node.js relay dependencies
cd telegram-relay
npm install
npm run build
cd ..
```

### 2. Create a Telegram bot

1. Open Telegram and find **@BotFather**
2. Send `/newbot`, choose a name and username
3. Copy the **bot token** you receive
4. Find **@userinfobot** in Telegram, send it any message
5. Copy your **numeric user ID**

### 3. Launch and configure

The app is now installed in `/Applications/ClaudeRemote.app`. Launch it from:
- Spotlight (Cmd+Space → "ClaudeRemote")
- Applications folder
- Or: `open /Applications/ClaudeRemote.app`

1. Click the icon in the menu bar
2. Click **Settings...** at the bottom
3. Go to **Telegram** section → **Configure...**
4. Enter your bot token and user ID
5. Click **Save & Test**
6. **Important:** Send `/start` to your bot in Telegram first, then test again

### 4. Configure Claude Code hooks

Add to `~/.claude/settings.json` (or the app does this automatically):

```json
{
  "hooks": {
    "Notification": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "~/path/to/claude-remote/scripts/notify-hook.sh"
      }]
    }],
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "~/path/to/claude-remote/scripts/notify-hook.sh"
      }]
    }]
  }
}
```

### 5. Set up the tmux launcher

Add to your `~/.zshrc`:

```bash
ca() {
  case "${1:-}" in
    attach)
      local latest
      latest=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude-' | tail -1)
      if [[ -n "$latest" ]]; then
        tmux attach-session -t "$latest"
      else
        echo "No claude-* sessions found. Run 'ca' to create one."
      fi
      ;;
    list)
      tmux list-sessions 2>/dev/null | grep '^claude-' || echo "No claude-* sessions found."
      ;;
    *)
      local session="claude-$(date +%H%M%S)"
      tmux new-session -s "$session" -- claude --chrome --permission-mode auto
      ;;
  esac
}
```

### 6. Start the relay

```bash
cd telegram-relay
npm start
```

## Updating

To rebuild and reinstall the app after making changes:

```bash
cd ClaudeRemote
make install
```

This will clean build, install to `/Applications`, and automatically set up keychain access.

## Usage

### Starting a session

```bash
ca              # Create a new Claude Code tmux session
ca attach       # Attach to the most recent session
ca list         # List all active sessions
```

### Menu bar app

- **Green icon** = at computer (notifications go to macOS)
- **Orange icon** = away (notifications go to Telegram)
- Click icon to see all sessions with state indicators and quick actions
- Click the **window icon** on a session to open the full app with terminal preview and input
- Click **Settings...** to configure presence detection, Telegram, and launch at login

### Telegram commands

| Command | Description |
|---------|-------------|
| `/y` or `/yes` | Approve permission prompt |
| `/n` or `/no` | Deny permission prompt |
| `/select <N>` | Select numbered option |
| `/status` | View last 50 lines of terminal output |
| `/screenshot` | Terminal rendered as an image |
| `/sessions` | List active tmux sessions |
| `/pane <id> <text>` | Send to a specific pane (multi-pane) |
| Free text | Sent directly to the waiting pane |

## Architecture

The hook script (`notify-hook.sh`) transforms Claude Code's hook JSON format (`hook_event_name`, `last_assistant_message`) into ClaudeRemote's expected format (`type`, `title`, `message`), enriches it with tmux context via `tmux capture-pane`, and POSTs the payload to the SwiftUI app's local HTTP listener on `127.0.0.1:7677`. The app routes notifications based on presence state.

The macOS app uses a robust `TmuxService` with dynamic tmux path discovery, async process execution with proper pipe handling, and exit code checking. Session state is detected by analyzing terminal content against known Claude Code prompt patterns (ported from the Telegram relay's TypeScript implementation).

The Telegram relay runs independently, polling for incoming messages. It dynamically discovers all `claude-*` tmux sessions and targets the correct pane that's waiting for input.

### Security

- HTTP listener bound to `127.0.0.1` only — no external access
- Shared secret (auto-generated, stored in Keychain) authenticates hook requests
- Telegram user ID whitelist — bot ignores messages from other users
- tmux input sanitized (single-quote wrapped, embedded quotes escaped)
- State-aware — relay verifies CC is waiting for input before sending keys

## License

[MIT](LICENSE)
