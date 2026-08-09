#!/usr/bin/env bash
# Runs every minute from cron. Appends one forensic block to the log so we
# have evidence from BEFORE an outage/restart. Truncated monthly by cleanup.sh.
# Every probe wrapped in `timeout` so a wedged docker daemon can't hang cron.
cd "$(dirname "$0")/.."

{
  echo "=== $(date '+%F %T')"

  # 1. What Traefik serves for the site (from inside server, Cloudflare bypassed)
  curl -sk -o /dev/null --max-time 10 \
    -w "traefik->web: http=%{http_code} time=%{time_total}s\n" \
    -H 'Host: drupal.community' https://localhost/health
  curl -sk -o /dev/null --max-time 10 \
    -w "traefik->streaming: http=%{http_code} time=%{time_total}s\n" \
    -H 'Host: drupal.community' https://localhost/api/v1/streaming/health

  # 2. Web container answering directly, Traefik bypassed
  timeout 15 docker exec mastodon-web-1 \
    curl -s -o /dev/null --max-time 10 -w "web direct: http=%{http_code} time=%{time_total}s\n" \
    localhost:3000/health 2>&1

  # 3. Containers + health state
  timeout 10 docker ps -a --format '{{.Names}} {{.Status}}'

  # 4. Web container health state + last recorded healthcheck output
  timeout 10 docker inspect --format '{{json .State.Health}}' mastodon-web-1 2>&1 \
    | tr -d '\n' | cut -c1-400 | sed 's/^/web health: /'
  echo

  # 5. Memory, swap, disk, load
  free -m | sed -n '2,3p'
  df -h / | sed -n '2p'
  uptime

  # 6. Top 5 memory eaters on host
  ps aux --sort=-%mem | awk 'NR<=6 {printf "%s %s%% %sMB %s\n", $1, $4, int($6/1024), $11}'

  # 7. Redis memory (noeviction at 512MB = writes fail)
  timeout 10 docker exec mastodon-redis-1 redis-cli info memory 2>&1 | grep used_memory_human

  # 8. Postgres connection count (max 200)
  timeout 10 docker exec db psql -U mastodon mastodon_production -tAc \
    'SELECT count(*) FROM pg_stat_activity' 2>&1 | sed 's/^/pg connections: /'
} >> /var/log/mastodon-watchdog.log 2>&1
