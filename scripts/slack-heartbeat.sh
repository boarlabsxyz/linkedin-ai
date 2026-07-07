#!/usr/bin/env bash
# Post an hourly "Heartbeat <UTC timestamp>" message to Slack via claude -p
# using the claude.ai Slack MCP connector. Invoked by the LaunchAgent at
# ~/Library/LaunchAgents/xyz.boarlabs.slack-heartbeat.plist (see
# scripts/xyz.boarlabs.slack-heartbeat.plist).
#
# Auth: claude -p reads the login-keychain "Claude Code-credentials" item,
# which carries the user:mcp_servers scope, exposing the Slack connector.
# The LaunchAgent MUST have SessionCreate=false so the process joins the
# login-window security session and can read the keychain.
set -euo pipefail

TS=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
HOST=$(hostname -s)

PROMPT="Post the message: Heartbeat (source=launchd, host=$HOST) $TS
to the Slack channel with URL: https://spdfn.slack.com/archives/C0BF606R4N7
(channel ID = C0BF606R4N7 — the segment after /archives/).

Rules:
- You MUST use the Slack MCP tool mcp__claude_ai_Slack__postMessage.
- Do NOT use Playwright, a browser, curl, a webhook, or any other fallback.
- The Slack MCP connector loads a few seconds after the process starts. If your first postMessage call fails because the tool is not yet registered, wait ~3 seconds and try again. Retry up to 3 times before giving up.
- Once the message is posted successfully, reply with a single line: POSTED ts=<message_ts> and stop."

printf '%s' "$PROMPT" | claude -p \
    --dangerously-skip-permissions \
    --allowed-tools "mcp__claude_ai_Slack__postMessage,mcp__claude_ai_Slack__listChannels" \
    --disallowed-tools "mcp__playwright__browser_navigate,mcp__playwright__browser_click,mcp__playwright__browser_type,mcp__playwright__browser_evaluate,mcp__playwright__browser_snapshot,mcp__playwright__browser_wait_for,mcp__playwright__browser_tabs,mcp__playwright__browser_press_key,Bash,WebFetch,WebSearch" \
    --output-format stream-json --verbose \
  | jq -r --unbuffered '
      .description
      // (.message?.content? | arrays | map(select(.type=="text") | .text) | .[])
      // (select(.is_error == true or .error) | "ERROR: \(.error // .message?.content)")
      // empty
    '
