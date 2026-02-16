#!/bin/bash
# Claude Code notification hook - enriches hook JSON with tmux context and forwards to ClaudeRemote app
# Reads CC hook JSON from stdin, adds tmux pane context + terminal snapshot, forwards to app

INPUT=$(cat)
PANE_ID="${TMUX_PANE:-}"

# Capture last 20 lines of terminal for context in Telegram messages
CONTEXT=$(tmux capture-pane -t "$PANE_ID" -p -S -20 2>/dev/null)

# Get tmux session name
SESSION_NAME=$(tmux display-message -p '#S' 2>/dev/null || echo "")

# Get working directory from the pane
WORKING_DIR=$(tmux display-message -t "$PANE_ID" -p '#{pane_current_path}' 2>/dev/null || echo "$PWD")

# Extract project name (last directory in path)
PROJECT_NAME=$(basename "$WORKING_DIR" 2>/dev/null || echo "")

ENRICHED=$(echo "$INPUT" | jq \
  --arg pane "$PANE_ID" \
  --arg ctx "$CONTEXT" \
  --arg session "$SESSION_NAME" \
  --arg workdir "$WORKING_DIR" \
  --arg project "$PROJECT_NAME" \
  '. + {tmux_pane: $pane, terminal_context: $ctx, tmux_session: $session, working_dir: $workdir, project_name: $project}')

curl -s -X POST http://127.0.0.1:7677/notify \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $(cat ~/.claude-remote-secret 2>/dev/null)" \
  -d "$ENRICHED" &>/dev/null &
