#!/usr/bin/env bash
# Monthly Mastodon cleanup — keeps postgres, media storage and docker slim.
# Run from cron as a user that can talk to docker.
set -uo pipefail
cd "$(dirname "$0")/.."  # repo root, where docker-compose.yml lives

log() { echo "[$(date '+%F %T')] $*"; }

# Ctrl+C stops the whole script, not just the current step.
trap 'log "interrupted"; exit 130' INT TERM

run() {
  log "START $*"
  # </dev/null: docker compose exec grabs stdin and reports "canceled"
  # when it's not a real terminal (cron, backgrounded shells).
  "$@" </dev/null || log "FAILED (continuing): $*"
}

# Remote toots older than 90 days, skipping anything a local user
# bookmarked/faved/boosted/replied to.
run docker compose exec -T web bin/tootctl statuses remove --days 90

# Link-preview cards older than 90 days.
run docker compose exec -T web bin/tootctl preview_cards remove --days 90

# Cached copies of remote media older than 14 days (re-fetched on demand).
run docker compose exec -T web bin/tootctl media remove --days 14

# Media files with no database record (object-storage bucket sweep — slow).
run docker compose exec -T web bin/tootctl media remove-orphans

# Remote accounts whose servers are gone.
run docker compose exec -T web bin/tootctl accounts cull

# Let postgres reclaim the space freed above.
run docker compose exec -T db psql -U mastodon mastodon_production -c "VACUUM ANALYZE;"

# Docker images unused for more than a week (old Mastodon versions).
run docker image prune -af --filter "until=168h"

log "cleanup done"
