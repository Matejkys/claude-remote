#!/bin/bash
# Claude Code notification hook - enriches hook JSON with tmux context and forwards to ClaudeRemote app
# Reads CC hook JSON from stdin, adds tmux pane context + terminal snapshot, forwards to app

INPUT=$(cat)
PANE_ID="${TMUX_PANE:-}"
# Capture last 20 lines of terminal for context in Telegram messages
CONTEXT=$(tmux capture-pane -t "$PANE_ID" -p -S -20 2>/dev/null)
ENRICHED=$(echo "$INPUT" | jq \
  --arg pane "$PANE_ID" \
  --arg ctx "$CONTEXT" \
  '. + {tmux_pane: $pane, terminal_context: $ctx}')
curl -s -X POST http://127.0.0.1:7677/notify \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $(cat ~/.claude-remote-secret 2>/dev/null)" \
  -d "$ENRICHED" &>/dev/null &
