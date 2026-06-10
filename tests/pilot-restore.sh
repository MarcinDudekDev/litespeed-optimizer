#!/bin/bash
# Pilot harness: restore an ARBITRARY WordPress export (files + DB) into a
# local OpenLiteSpeed + MariaDB + Redis Docker stack, search-replace the live
# URL to a local .loc domain, and expose wp-cli for the optimizer to drive.
#
# Reuses the e2e-woo container topology. The export is CLIENT DATA: it stays
# local, is never committed, and lives under a gitignored path.
#
# Usage:
#   tests/pilot-restore.sh <export-dir> [live-url] [loc-domain]
#
#   <export-dir>  directory containing the WP files (wp-content etc.) and a
#                 single .sql / .sql.gz dump (DB). Layout-tolerant: it finds
#                 wp-config-less file trees and the largest .sql it can see.
#   live-url      original site URL (auto-detected from the DB siteurl if omitted)
#   loc-domain    local hostname to map to (default: mltools.loc)
#
# Leaves the stack running (containers lso-pilot-ols / lso-pilot-db) so the
# pilot report script can drive analyze/optimize/benchmark against it.
# Env: LSO_PILOT_KEEP=0 to tear down on exit (default keeps it up).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

EXPORT_DIR="${1:-}"
LIVE_URL="${2:-}"
LOC_DOMAIN="${3:-mltools.loc}"

NET="lso-pilot-net"
DB="lso-pilot-db"
OLS="lso-pilot-ols"
PORT="${LSO_PILOT_PORT:-18090}"
BASE="http://${LOC_DOMAIN}:${PORT}"
IMAGE="litespeedtech/openlitespeed:latest"
DB_IMAGE="mariadb:11"
DBPASS="pilot-localpass"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
say()  { echo -e "${GREEN}[pilot]${NC} $*"; }
warn() { echo -e "${YELLOW}[pilot]${NC} $*"; }
die()  { echo -e "${RED}[pilot]${NC} $*" >&2; exit 1; }

[ -n "$EXPORT_DIR" ] || die "usage: pilot-restore.sh <export-dir> [live-url] [loc-domain]"
[ -d "$EXPORT_DIR" ] || die "export dir not found: $EXPORT_DIR"
command -v docker &>/dev/null && docker info >/dev/null 2>&1 || die "Docker unavailable"

# Locate the file tree (dir containing wp-content) and the DB dump
WP_FILES=""
if [ -d "$EXPORT_DIR/wp-content" ]; then
    WP_FILES="$EXPORT_DIR"
else
    WP_FILES=$(dirname "$(find "$EXPORT_DIR" -maxdepth 3 -type d -name wp-content 2>/dev/null | head -1)" 2>/dev/null)
fi
[ -n "$WP_FILES" ] && [ -d "$WP_FILES/wp-content" ] || die "no wp-content/ found under $EXPORT_DIR"

DB_DUMP=$(find "$EXPORT_DIR" -maxdepth 3 \( -name '*.sql' -o -name '*.sql.gz' \) 2>/dev/null | \
    while read -r f; do echo "$(wc -c <"$f" 2>/dev/null || echo 0) $f"; done | sort -rn | head -1 | cut -d' ' -f2-)
[ -n "$DB_DUMP" ] && [ -f "$DB_DUMP" ] || die "no .sql/.sql.gz dump found under $EXPORT_DIR"

say "Files:  $WP_FILES"
say "DB:     $DB_DUMP"
say "Target: ${BASE}  (live: ${LIVE_URL:-auto-detect})"

cleanup() {
    if [ "${LSO_PILOT_KEEP:-1}" = "1" ]; then
        say "stack left running (LSO_PILOT_KEEP=1): $OLS / $DB on ${BASE}"
        return 0
    fi
    docker rm -f "$OLS" "$DB" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker rm -f "$OLS" "$DB" >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true

in_ols() { docker exec "$OLS" bash -c "$*"; }
DOCROOT="/usr/local/lsws/Example/html"
wp_in() { docker exec "$OLS" bash -c "cd $DOCROOT && wp --allow-root $*"; }

say "Starting stack..."
docker network create "$NET" >/dev/null
docker run -d --name "$DB" --network "$NET" \
    -e MARIADB_DATABASE=wp -e MARIADB_USER=wp -e MARIADB_PASSWORD="$DBPASS" \
    -e MARIADB_ROOT_PASSWORD="$DBPASS" "$DB_IMAGE" >/dev/null
docker run -d --name "$OLS" --network "$NET" \
    -p "${PORT}:8088" --add-host "${LOC_DOMAIN}:127.0.0.1" "$IMAGE" >/dev/null

say "Waiting for MariaDB..."
for i in $(seq 1 60); do
    docker exec "$DB" mariadb -uwp -p"$DBPASS" -e "SELECT 1" wp >/dev/null 2>&1 && break
    sleep 2
    [ "$i" -eq 60 ] && die "MariaDB never came up"
done

say "Provisioning OLS (php, redis, wp-cli)..."
in_ols "apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq rsync curl redis-server >/dev/null 2>&1" || true
PHPBIN=$(in_ols "ls /usr/local/lsws/lsphp*/bin/php 2>/dev/null | sort | tail -1" | tr -d '\r')
[ -n "$PHPBIN" ] || die "no lsphp in image"
PHPVER=$(echo "$PHPBIN" | sed -n 's|.*/lsphp\([0-9]*\)/.*|\1|p')
in_ols "apt-get install -y -qq lsphp${PHPVER}-redis lsphp${PHPVER}-mysql >/dev/null 2>&1" || true
in_ols "redis-server --daemonize yes --save '' --appendonly no" || true
in_ols "curl -sLo /usr/local/bin/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && printf '#!/bin/sh\nexec ${PHPBIN} /usr/local/bin/wp-cli.phar \"\$@\"\n' > /usr/local/bin/wp && chmod +x /usr/local/bin/wp"

# Make Example a real WP host: index.php first, rewrite engine on (LSCWP vary!)
in_ols "rm -f ${DOCROOT}/index.html ${DOCROOT}/*.php 2>/dev/null; perl -pi -e 's/indexFiles index.html/indexFiles index.php, index.html/' /usr/local/lsws/conf/vhosts/Example/vhconf.conf; perl -0pi -e 's/rewrite \{\n  enable 0/rewrite \{\n  enable 1\n  autoLoadHtaccess 1/' /usr/local/lsws/conf/vhosts/Example/vhconf.conf"

say "Copying client files into container..."
docker cp "$WP_FILES/." "$OLS:${DOCROOT}/"
in_ols "chown -R lsadm:lsadm ${DOCROOT} 2>/dev/null || true"

say "Importing database..."
case "$DB_DUMP" in
    *.gz) gunzip -c "$DB_DUMP" | docker exec -i "$DB" mariadb -uwp -p"$DBPASS" wp ;;
    *)    docker exec -i "$DB" mariadb -uwp -p"$DBPASS" wp < "$DB_DUMP" ;;
esac || die "DB import failed"

# Generate a matching wp-config (DB creds point at the pilot container)
in_ols "rm -f ${DOCROOT}/wp-config.php"
TABLE_PREFIX=$(docker exec "$DB" mariadb -uwp -p"$DBPASS" -N -e \
    "SELECT SUBSTRING_INDEX(table_name,'options',1) FROM information_schema.tables WHERE table_schema='wp' AND table_name LIKE '%options' LIMIT 1" 2>/dev/null | tr -d '\r')
[ -n "$TABLE_PREFIX" ] || TABLE_PREFIX="wp_"
say "Table prefix: ${TABLE_PREFIX}"
wp_in "config create --dbname=wp --dbuser=wp --dbpass=${DBPASS} --dbhost=${DB} --dbprefix='${TABLE_PREFIX}' --skip-check --force" \
    || die "wp config create failed"

# Auto-detect the live URL from the DB if not supplied
if [ -z "$LIVE_URL" ]; then
    LIVE_URL=$(wp_in "option get siteurl --skip-plugins --skip-themes" 2>/dev/null | tr -d '\r')
fi
[ -n "$LIVE_URL" ] || die "could not determine live URL (pass it as arg 2)"
say "Live URL: ${LIVE_URL}  ->  ${BASE}"

say "Search-replace to local domain..."
wp_in "search-replace '${LIVE_URL}' '${BASE}' --all-tables --skip-columns=guid --report-changed-only --skip-plugins --skip-themes" || warn "search-replace had warnings"
# Also map bare-host https/http variants to be safe
LIVE_HOST=$(echo "$LIVE_URL" | sed -E 's#https?://##; s#/.*##')
wp_in "search-replace '//${LIVE_HOST}' '//${LOC_DOMAIN}:${PORT}' --all-tables --skip-columns=guid --report-changed-only --skip-plugins --skip-themes" 2>/dev/null || true

# Neutralize anything that would phone home / break locally
wp_in "config set WP_ENVIRONMENT_TYPE staging --type=constant" 2>/dev/null || true
wp_in "config set DISABLE_WP_CRON true --raw --type=constant" 2>/dev/null || true
wp_in "config set WP_CACHE true --raw --type=constant" 2>/dev/null || true

# Ensure an admin we control (don't touch existing client accounts' passwords
# beyond creating a dedicated local admin)
if ! wp_in "user get lso-pilot --field=ID" >/dev/null 2>&1; then
    wp_in "user create lso-pilot pilot@${LOC_DOMAIN} --role=administrator --user_pass=admin123" 2>/dev/null \
        || warn "could not create pilot admin (continuing)"
fi

wp_in "cache flush" 2>/dev/null || true
in_ols "/usr/local/lsws/bin/lswsctrl restart" >/dev/null 2>&1
sleep 3

# Smoke check
CODE=$(curl -s -o /dev/null -m 15 -w '%{http_code}' -H "Host: ${LOC_DOMAIN}" "http://127.0.0.1:${PORT}/" || echo 000)
if [ "$CODE" != "000" ]; then
    say "Restore complete — ${BASE} responds HTTP ${CODE}"
    say "Add to /etc/hosts for browser access: 127.0.0.1 ${LOC_DOMAIN}"
    say "Drive it: docker exec $OLS bash -c 'cd /opt/lso && ./litespeed-optimizer.sh ...'"
else
    warn "site not responding yet (HTTP 000) — check: docker logs $OLS"
fi

# Deploy the tool into the container for the report script
in_ols "mkdir -p /opt/lso"
docker cp "$ROOT_DIR/litespeed-optimizer.sh" "$OLS:/opt/lso/"
docker cp "$ROOT_DIR/lib" "$OLS:/opt/lso/lib"
docker cp "$ROOT_DIR/litespeed-optimizer-lib" "$OLS:/opt/lso/litespeed-optimizer-lib"
docker cp "$ROOT_DIR/templates" "$OLS:/opt/lso/templates"
say "Tool deployed to ${OLS}:/opt/lso  — ready for tests/pilot-report.sh"
