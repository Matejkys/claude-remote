#!/bin/bash
# Claude Code notification hook - transforms CC hook JSON into ClaudeRemote format,
# enriches with tmux context, and forwards to the ClaudeRemote HTTP listener.
#
# Claude Code sends: {hook_event_name, last_assistant_message, session_id, cwd, ...}
# ClaudeRemote expects: {type, title, message, tmux_pane, terminal_context, ...}

INPUT=$(cat)
PANE_ID="${TMUX_PANE:-}"

# Capture terminal context for Telegram messages
CONTEXT=$(tmux capture-pane -t "$PANE_ID" -p -S -20 2>/dev/null)

# Get tmux session name
SESSION_NAME=$(tmux display-message -p '#S' 2>/dev/null || echo "")

# Get working directory from the pane
WORKING_DIR=$(tmux display-message -t "$PANE_ID" -p '#{pane_current_path}' 2>/dev/null || echo "$PWD")

# Extract project name (last directory in path)
PROJECT_NAME=$(basename "$WORKING_DIR" 2>/dev/null || echo "")

# Transform Claude Code hook format to ClaudeRemote format and enrich with tmux context.
# Maps: hook_event_name -> type, last_assistant_message -> message
# Generates title based on event type.
PAYLOAD=$(echo "$INPUT" | jq \
  --arg pane "$PANE_ID" \
  --arg ctx "$CONTEXT" \
  --arg session "$SESSION_NAME" \
  --arg workdir "$WORKING_DIR" \
  --arg project "$PROJECT_NAME" \
  '{
    type: (if .hook_event_name == "Stop" then "Stop"
           elif .hook_event_name == "Notification" then "Notification"
           elif .type then .type
           else "Notification" end),
    title: (if .hook_event_name == "Stop" then "Claude finished"
            elif .hook_event_name == "Notification" then (.title // "Claude Code")
            elif .title then .title
            else "Claude Code" end),
    message: (.last_assistant_message // .message // ""),
    tmux_pane: $pane,
    terminal_context: $ctx,
    tmux_session: $session,
    working_dir: $workdir,
    project_name: $project
  }')

curl -s -X POST http://127.0.0.1:7677/notify \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $(cat ~/.claude-remote-secret 2>/dev/null)" \
  -d "$PAYLOAD" &>/dev/null &
