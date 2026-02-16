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

When you're at your Mac, you get native macOS notifications. When you're away, notifications go to Telegram with full terminal context, and you can reply to approve/deny permissions, answer questions, or send any input back to Claude Code.

## Components

| Component | Tech | Purpose |
|-----------|------|---------|
| **ClaudeRemote** | SwiftUI (macOS 14+) | Menu bar app — presence detection, notification routing, settings |
| **telegram-relay** | Node.js + TypeScript | Telegram bot — long-polling, tmux interaction, command handling |
| **notify-hook.sh** | Bash | Claude Code hook — enriches notifications with tmux context |

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

# Build the macOS menu bar app
cd ClaudeRemote
make bundle
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

```bash
# Start the menu bar app
open ClaudeRemote/build/ClaudeRemote.app
```

1. Click the antenna icon in the menu bar
2. Go to **Telegram** section → **Configure...**
3. Enter your bot token and user ID
4. Click **Save & Test**
5. **Important:** Send `/start` to your bot in Telegram first, then test again

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
cy() {
  case "${1:-}" in
    attach)
      local latest
      latest=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude-' | tail -1)
      if [[ -n "$latest" ]]; then
        tmux attach-session -t "$latest"
      else
        echo "No claude-* sessions found. Run 'cy' to create one."
      fi
      ;;
    list)
      tmux list-sessions 2>/dev/null | grep '^claude-' || echo "No claude-* sessions found."
      ;;
    *)
      local session="claude-$(date +%H%M%S)"
      tmux new-session -s "$session" -- claude --chrome --dangerously-skip-permissions
      ;;
  esac
}
```

### 6. Start the relay

```bash
cd telegram-relay
npm start
```

## Usage

### Starting a session

```bash
cy              # Create a new Claude Code tmux session
cy attach       # Attach to the most recent session
cy list         # List all active sessions
```

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

### Menu bar app

- **Green icon** = at computer (notifications go to macOS)
- **Orange icon** = away (notifications go to Telegram)
- Manage tmux sessions: copy attach command, kill sessions
- Configure presence detection thresholds and notification preferences

## Architecture

The hook script (`notify-hook.sh`) captures terminal context via `tmux capture-pane` and POSTs enriched JSON to the SwiftUI app's local HTTP listener on `127.0.0.1:7677`. The app routes notifications based on presence state.

The Telegram relay runs independently, polling for incoming messages. It dynamically discovers all `claude-*` tmux sessions and targets the correct pane that's waiting for input.

### Security

- HTTP listener bound to `127.0.0.1` only — no external access
- Shared secret (auto-generated, stored in Keychain) authenticates hook requests
- Telegram user ID whitelist — bot ignores messages from other users
- tmux input sanitized (single-quote wrapped, embedded quotes escaped)
- State-aware — relay verifies CC is waiting for input before sending keys

## License

[MIT](LICENSE)
