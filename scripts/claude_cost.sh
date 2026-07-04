#!/usr/bin/env bash
# Status-line renderer for Claude Code: model | context % | session cost | duration | lines.
#
# Claude Code invokes this on every status-line refresh, piping a JSON object on
# stdin. Everything shown here comes straight from that payload — no transcript
# parsing, no rate table, no provider API call. In particular `cost.total_cost_usd`
# is the session cost Claude Code already computes client-side, so we just format
# it rather than re-deriving it from token counts.
#
# Fields consumed (all optional; each falls back gracefully):
#   .model.display_name                  -> model label
#   .context_window.used_percentage      -> context window % used
#   .cost.total_cost_usd                 -> estimated session cost (USD)
#   .cost.total_duration_ms              -> wall-clock time since session start
#   .cost.total_lines_added/_removed     -> lines of code changed
#
# jq does the JSON parsing when available. If jq is missing we degrade to a
# grep/sed fallback so the status line still renders instead of going blank.

set -euo pipefail

input=$(cat)

RESET=$'\033[0m'
DIM=$'\033[2m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
MAGENTA=$'\033[35m'

if command -v jq >/dev/null 2>&1; then
  # One jq pass emits the fields we need, tab-separated, with null-safe defaults.
  # BRANCH: worktree branch Claude Code already reports, if any; authoritative when set.
  IFS=$'\t' read -r MODEL PCT COST DURATION_MS ADDED REMOVED CWD BRANCH <<EOF
$(jq -r '
    [ (.model.display_name // .model.id // "?")
    , (.context_window.used_percentage // 0 | floor)
    , (.cost.total_cost_usd // 0)
    , (.cost.total_duration_ms // 0 | floor)
    , (.cost.total_lines_added // 0)
    , (.cost.total_lines_removed // 0)
    , (.workspace.current_dir // .cwd // "")
    , (.worktree.branch // .workspace.git_worktree // "")
    ] | @tsv' <<<"$input")
EOF
else
  # jq-less fallback: pull scalars by hand (best-effort); jq is the supported path.
  # `|| true` on each grep: an absent field (no match, exit 1) must not trip `set -e`.
  MODEL=$(grep -o '"display_name":"[^"]*"' <<<"$input" | head -1 | cut -d'"' -f4 || true)
  MODEL=${MODEL:-?}
  PCT=$(grep -o '"used_percentage":[0-9.]*' <<<"$input" | head -1 | cut -d: -f2 | cut -d. -f1 || true)
  PCT=${PCT:-0}
  COST=$(grep -o '"total_cost_usd":[0-9.]*' <<<"$input" | head -1 | cut -d: -f2 || true)
  COST=${COST:-0}
  DURATION_MS=$(grep -o '"total_duration_ms":[0-9]*' <<<"$input" | head -1 | cut -d: -f2 || true)
  DURATION_MS=${DURATION_MS:-0}
  ADDED=$(grep -o '"total_lines_added":[0-9]*' <<<"$input" | head -1 | cut -d: -f2 || true)
  ADDED=${ADDED:-0}
  REMOVED=$(grep -o '"total_lines_removed":[0-9]*' <<<"$input" | head -1 | cut -d: -f2 || true)
  REMOVED=${REMOVED:-0}
  CWD=$(grep -o '"current_dir":"[^"]*"' <<<"$input" | head -1 | cut -d'"' -f4 || true)
  [ -z "$CWD" ] && CWD=$(grep -o '"cwd":"[^"]*"' <<<"$input" | head -1 | cut -d'"' -f4 || true)
  BRANCH=$(grep -o '"branch":"[^"]*"' <<<"$input" | head -1 | cut -d'"' -f4 || true)
  [ -z "$BRANCH" ] && BRANCH=$(grep -o '"git_worktree":"[^"]*"' <<<"$input" | head -1 | cut -d'"' -f4 || true)
fi

# Context bar colors by usage: green < 70%, yellow 70-89%, red 90%+.
if [ "$PCT" -ge 90 ]; then
  PCT_COLOR="$RED"
elif [ "$PCT" -ge 70 ]; then
  PCT_COLOR="$YELLOW"
else
  PCT_COLOR="$GREEN"
fi

# ms -> m/s without floats.
DURATION_SEC=$((DURATION_MS / 1000))
MINS=$((DURATION_SEC / 60))
SECS=$((DURATION_SEC % 60))

COST_FMT=$(printf '$%.2f' "$COST")

SEP=" ${DIM}|${RESET} "
LINE1="${CYAN}${MODEL}${RESET}"
LINE1="${LINE1}${SEP}${PCT_COLOR}${PCT}% ctx${RESET}"
LINE1="${LINE1}${SEP}${GREEN}${COST_FMT}${RESET}"
LINE1="${LINE1}${SEP}${DIM}${MINS}m ${SECS}s${RESET}"
if [ "$ADDED" -gt 0 ] || [ "$REMOVED" -gt 0 ]; then
  LINE1="${LINE1}${SEP}${DIM}+${ADDED} -${REMOVED}${RESET}"
fi

# Second line: folder (leaf of current_dir) + git branch. Both degrade to nothing.
FOLDER="${CWD##*/}"
# Fall back to git only when the payload gave no branch; -C "$CWD" resolves this worktree.
if [ -z "$BRANCH" ] && [ -n "$CWD" ] && command -v git >/dev/null 2>&1; then
  BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || true)
fi

LINE2=""
[ -n "$FOLDER" ] && LINE2="${DIM}📁${RESET} ${MAGENTA}${FOLDER}${RESET}"
if [ -n "$BRANCH" ]; then
  [ -n "$LINE2" ] && LINE2="${LINE2}${SEP}"
  LINE2="${LINE2}${DIM}🌿${RESET} ${YELLOW}${BRANCH}${RESET}"
fi

printf '%s' "$LINE1"
[ -n "$LINE2" ] && printf '\n%s' "$LINE2"
