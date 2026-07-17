#!/usr/bin/env bash
# Fire the linkedin-comment-hourly skill once a day (06:00 local, Tue–Fri).
# Entry point for the xyz.boarlabs.slack-heartbeat LaunchAgent (see
# xyz.boarlabs.slack-heartbeat.plist and cron-wrapper.sh, which hard-resets
# worker/ to origin/main before invoking this script).
#
# The historical "post a heartbeat to Slack" behavior is retired — the same
# LaunchAgent now runs the LinkedIn comment-ideas pipeline via run-hourly.sh:
#   1. Post a 🟢 run-started bookend to Slack channel C0BF606R4N7.
#   2. Scrape 5 unseen, on-topic, not-already-commented posts from the home feed.
#   3. Draft 2-3 comment variants per post via the linkedin-comment-ideas skill.
#   4. Append one entry per post to ./linkedin-compain/comments.json.
#   5. Post one message per post to Slack channel C0BF606R4N7.
#   6. Commit + push + auto-merge as a PR.
#   7. Post a ✅/⚠️/❌ run-finished bookend with counts, duration, and PR URL.
#
# Auth: same as before — claude -p reads the login-keychain "Claude Code-credentials"
# item, which carries the user:mcp_servers scope, exposing the Slack + GDrive + GDoc
# connectors. The LaunchAgent MUST have SessionCreate=false so the process joins the
# login-window security session and can read the keychain.
set -euo pipefail

exec "$(dirname "$0")/../.claude/skills/linkedin-comment-hourly/run-hourly.sh"
