#!/bin/bash
#
# transfer-spark-meeting-notes.sh
#
# Daily job (launchd): pull new meeting-note summaries from the Spark mail app
# and commit them to the sonobe-brain monorepo (meeting-notes/).
#
#   - Summary only (spark meeting <id>, no --transcript) per user preference.
#   - Dedup via a git-tracked, per-user manifest of already-processed IDs.
#   - Multi-writer safe: rebases on the remote before committing, pushes any
#     local commits even when this run found nothing new.
#
# Config via environment (optional):
#   SPARK_MEETING_NOTES_REPO  path to the sonobe-brain clone
#   SPARK_BIN               path to the spark CLI
#
# Managed by ~/Library/LaunchAgents/nl.sonobe.spark-meeting-notes.plist
# See README.md for setup and the multi-writer / team design.

set -uo pipefail

# launchd gives a minimal PATH; pin the tools we call.
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly REPO="${SPARK_MEETING_NOTES_REPO:-$HOME/Development/sonobe-brain}"
readonly DEST="$REPO/meeting-notes"
# Per-user manifest so teammates can write to the same repo without fighting
# over one shared dedup file (their meeting IDs never collide with ours anyway).
readonly MANIFEST="$DEST/.processed-ids-$(id -un)"
readonly SPARK="${SPARK_BIN:-/usr/local/bin/spark}"
readonly SPARK_APP="Spark Desktop"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

log "=== run start ==="

[ -x "$SPARK" ]   || die "spark CLI not found at $SPARK"
[ -d "$REPO/.git" ] || die "repo not found at $REPO"
mkdir -p "$DEST"
touch "$MANIFEST"

# --- Ensure Spark Desktop is up (the CLI is a thin IPC client) -------------
open -a "$SPARK_APP" >/dev/null 2>&1 || log "warn: could not 'open -a $SPARK_APP'"

ready=""
for _ in $(seq 1 30); do
  if "$SPARK" accounts >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done
[ -n "$ready" ] || die "Spark Desktop did not become reachable within ~60s"

# --- List meeting IDs (newest first), skip ones we've already saved --------
meetings_out="$("$SPARK" meetings --page-size 200 2>&1)" \
  || die "spark meetings failed: $meetings_out"

# Meeting rows look like:  "  11728  Strategische Bespreking ...  2026-06-02 20:35  1h 1m"
all_ids="$(printf '%s\n' "$meetings_out" | awk '/^[[:space:]]+[0-9]+[[:space:]]/ {print $1}')"
[ -n "$all_ids" ] || { log "no meetings reported by Spark; nothing to do"; log "=== run end ==="; exit 0; }

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

new_count=0
new_dates=""
while IFS= read -r id; do
  [ -n "$id" ] || continue
  if grep -qx "$id" "$MANIFEST"; then
    continue   # already processed
  fi

  body="$("$SPARK" meeting "$id" 2>&1)" || { log "warn: spark meeting $id failed, skipping: $body"; continue; }

  title="$(printf '%s\n' "$body" | sed -n 's/^Meeting:[[:space:]]*//p' | head -1)"
  date="$(printf '%s\n'  "$body" | sed -n 's/^Date:[[:space:]]*\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\).*/\1/p' | head -1)"
  [ -n "$date" ] || date="$(date '+%Y-%m-%d')"

  slug="$(slugify "${title:-}")"
  [ -n "$slug" ] || slug="meeting-$id"
  file="$DEST/${date}-${slug}.md"

  printf '%s\n' "$body" > "$file" || { log "warn: could not write $file, skipping id $id"; continue; }
  printf '%s\n' "$id" >> "$MANIFEST"
  log "saved id=$id -> $(basename "$file")"
  new_count=$((new_count + 1))
  new_dates="$new_dates $date"
done <<< "$all_ids"

branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"

# --- Sync with teammates first (multi-writer repo) --------------------------
# Always rebase onto the latest remote so we (a) pick up their new transcripts
# and (b) keep our own push a clean fast-forward. --autostash guards stray edits;
# our freshly written files are still untracked here, so rebase leaves them be.
git -C "$REPO" pull --rebase --autostash origin "$branch" >/dev/null 2>&1 \
  || log "warn: pull --rebase failed (continuing; push may need a manual sync)"

# --- Commit (only when this run actually found something new) ----------------
if [ "$new_count" -gt 0 ]; then
  uniq_dates="$(printf '%s\n' $new_dates | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  msg="Add meeting transcript(s) from ${uniq_dates}"

  git -C "$REPO" add meeting-notes/ || die "git add failed"
  git -C "$REPO" commit -q -m "$msg" || die "git commit failed"
  log "committed: $msg"
else
  log "no new transcripts"
fi

# --- Push any commits ahead of origin, including a prior run's failed push ---
# Decoupled from new_count: a commit that failed to push yesterday still gets
# shipped today even when this run found nothing new.
if [ -n "$(git -C "$REPO" rev-list "origin/$branch..HEAD" 2>/dev/null)" ]; then
  if git -C "$REPO" push origin "$branch" >/dev/null 2>&1; then
    log "pushed to origin/$branch"
  else
    log "warn: git push failed (commit(s) remain local; will retry next run)"
  fi
else
  log "nothing to push"
fi

log "=== run end ($new_count new) ==="
