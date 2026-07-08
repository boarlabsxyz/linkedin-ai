#!/usr/bin/env bash
# Fire the linkedin-comment-hourly skill every 15 minutes. Entry point for the
# xyz.boarlabs.slack-heartbeat LaunchAgent (see xyz.boarlabs.slack-heartbeat.plist
# and cron-wrapper.sh, which hard-resets worker/ to origin/main before invoking
# this script).
#
# The historical "post a heartbeat to Slack" behavior is retired — the same
# LaunchAgent now runs the LinkedIn comment-ideas pipeline via run-hourly.sh:
#   1. Scrape 5 unseen, on-topic, not-already-commented posts from the home feed.
#   2. Draft 2-3 comment variants per post via the linkedin-comment-ideas skill.
#   3. Save one JSON per post under ./linkedin-compain/comments/.
#   4. Post one message per post to Slack channel C0BF606R4N7.
#   5. Commit + push + auto-merge the JSONs as a PR.
#
# Auth: same as before — claude -p reads the login-keychain "Claude Code-credentials"
# item, which carries the user:mcp_servers scope, exposing the Slack + GDrive + GDoc
# connectors. The LaunchAgent MUST have SessionCreate=false so the process joins the
# login-window security session and can read the keychain.
set -euo pipefail

exec "$(dirname "$0")/../.claude/skills/linkedin-comment-hourly/run-hourly.sh"
