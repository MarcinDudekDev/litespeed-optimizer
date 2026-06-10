#!/bin/bash
# Extended Docker E2E: litespeed-optimizer against a REAL WordPress +
# WooCommerce store on OpenLiteSpeed (+ MariaDB container, Redis in-container).
#
# Flow: build stack -> install WP+Woo+products -> analyze (before) ->
# optimize --profile woocommerce -> analyze (after) -> benchmark ->
# cache-correctness checks (product hit, cart not cached, two-session
# isolation) -> LSCWP option spot-checks -> Redis check -> rollback test.
#
# Results land in docs/E2E-REPORT.md (honest reporting — failures included).
# Heavy (~5-10 min): manual CI trigger only (workflow_dispatch).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPORT="${ROOT_DIR}/docs/E2E-REPORT.md"

NET="lso-woo-net"
DB="lso-woo-db"
OLS="lso-woo-ols"
PORT=18089
BASE="http://localhost:${PORT}"
IMAGE="litespeedtech/openlitespeed:latest"
DB_IMAGE="mariadb:11"
# Local-only throwaway DB password (containers are removed after the run)
DBPASS="wppass-e2e"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0
RESULTS=""

log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); RESULTS="${RESULTS}| PASS | $* |
"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); RESULTS="${RESULTS}| FAIL | $* |
"; }
log_note() { echo -e "${YELLOW}[NOTE]${NC} $*"; RESULTS="${RESULTS}| NOTE | $* |
"; }

if ! command -v docker &>/dev/null || ! docker info >/dev/null 2>&1; then
    echo -e "${YELLOW}[SKIP]${NC} Docker unavailable — e2e-woo is a CI/manual target"
    exit 0
fi

cleanup() {
    if [ "${LSO_E2E_KEEP:-0}" = "1" ]; then
        echo "LSO_E2E_KEEP=1 — leaving containers ${OLS}/${DB} running for debugging"
        return 0
    fi
    docker rm -f "$OLS" "$DB" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker rm -f "$OLS" "$DB" >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true

in_ols() { docker exec "$OLS" bash -c "$*"; }
wp_in() { docker exec "$OLS" bash -c "cd /usr/local/lsws/Example/html && wp --allow-root $*"; }

echo "=== WP+WooCommerce E2E: building stack ==="
docker network create "$NET" >/dev/null
docker run -d --name "$DB" --network "$NET" \
    -e MARIADB_DATABASE=wp -e MARIADB_USER=wp -e MARIADB_PASSWORD="$DBPASS" \
    -e MARIADB_ROOT_PASSWORD="$DBPASS" "$DB_IMAGE" >/dev/null
docker run -d --name "$OLS" --network "$NET" -p "${PORT}:8088" "$IMAGE" >/dev/null

echo "Waiting for MariaDB..."
for i in $(seq 1 60); do
    if docker exec "$DB" mariadb -uwp -p"$DBPASS" -e "SELECT 1" wp >/dev/null 2>&1; then break; fi
    sleep 2
    [ "$i" -eq 60 ] && { echo "MariaDB never came up"; exit 1; }
done

echo "Provisioning OLS container (packages, redis, wp-cli)..."
in_ols "apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq rsync curl redis-server >/dev/null 2>&1" || true

# PHP + wp-cli wrapper
PHPBIN=$(in_ols "ls /usr/local/lsws/lsphp*/bin/php 2>/dev/null | sort | tail -1" | tr -d '\r')
if [ -z "$PHPBIN" ]; then
    echo "No lsphp binary found in image"; exit 1
fi
PHPVER=$(echo "$PHPBIN" | sed -n 's|.*/lsphp\([0-9]*\)/.*|\1|p')
echo "PHP: $PHPBIN (lsphp${PHPVER})"
in_ols "apt-get install -y -qq lsphp${PHPVER}-redis lsphp${PHPVER}-mysql >/dev/null 2>&1" || true
in_ols "redis-server --daemonize yes --save '' --appendonly no" || true
in_ols "curl -sLo /usr/local/bin/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && printf '#!/bin/sh\nexec ${PHPBIN} /usr/local/bin/wp-cli.phar \"\$@\"\n' > /usr/local/bin/wp && chmod +x /usr/local/bin/wp"

# retry <n> <cmd...> — wordpress.org can be slow; retry transient timeouts
retry() {
    local n="$1" i
    shift
    for i in $(seq 1 "$n"); do
        if "$@"; then return 0; fi
        echo "  (attempt $i/$n failed, retrying...)"
        sleep 5
    done
    return 1
}

echo "Installing WordPress..."
retry 3 wp_in "core download --quiet --force" || { echo "WP download failed"; exit 1; }
wp_in "config create --dbname=wp --dbuser=wp --dbpass=${DBPASS} --dbhost=${DB} --quiet"
wp_in "core install --url=${BASE} --title='LSO E2E Store' --admin_user=admin --admin_password=admin123 --admin_email=marcin.dudek.dev@gmail.com --skip-email --quiet" || { echo "WP install failed"; exit 1; }

# Make the Example vhost a proper WP host (as ols1clk would): index.php first,
# rewrite engine ON (LSCWP vary cookies are .htaccess rewrite rules — with
# rewrite disabled, cookie vary silently breaks and carts cache-poison).
in_ols "rm -f /usr/local/lsws/Example/html/index.html && perl -pi -e 's/indexFiles index.html/indexFiles index.php, index.html/' /usr/local/lsws/conf/vhosts/Example/vhconf.conf && perl -0pi -e 's/rewrite \{\n  enable 0/rewrite \{\n  enable 1\n  autoLoadHtaccess 1/' /usr/local/lsws/conf/vhosts/Example/vhconf.conf && /usr/local/lsws/bin/lswsctrl restart" >/dev/null 2>&1
sleep 3

echo "Installing WooCommerce + products..."
retry 3 wp_in "plugin install woocommerce --activate --quiet" || { echo "Woo install failed"; exit 1; }
wp_in "wc product create --name='E2E Widget' --type=simple --regular_price=19.99 --status=publish --user=admin --porcelain" > /tmp/lso-prod1.txt || true
PROD_ID=$(tr -dc '0-9' < /tmp/lso-prod1.txt)
if [ -z "$PROD_ID" ]; then
    echo "Product creation failed"; exit 1
fi
PROD_URL=$(wp_in "eval 'echo get_permalink(${PROD_ID});'" | tr -d '\r')
CART_URL=$(wp_in "eval 'echo wc_get_cart_url();'" | tr -d '\r')
echo "Product: $PROD_URL  Cart: $CART_URL"

# Deploy the tool into the container
in_ols "mkdir -p /opt/lso"
docker cp "$ROOT_DIR/litespeed-optimizer.sh" "$OLS:/opt/lso/"
docker cp "$ROOT_DIR/lib" "$OLS:/opt/lso/lib"
docker cp "$ROOT_DIR/litespeed-optimizer-lib" "$OLS:/opt/lso/litespeed-optimizer-lib"
docker cp "$ROOT_DIR/templates" "$OLS:/opt/lso/templates"
run_tool() { docker exec "$OLS" bash -c "cd /opt/lso && ./litespeed-optimizer.sh $*"; }

############################################################
# 1. detect / check
############################################################
detect_out=$(run_tool "detect --json" 2>/dev/null || true)
if echo "$detect_out" | grep -q '"edition": *"ols"' && echo "$detect_out" | grep -q "Example/html"; then
    log_pass "detect: OLS + WP site (Example/html) discovered"
else
    log_fail "detect: WP site not discovered: $(echo "$detect_out" | head -2)"
fi

if run_tool "check" >/dev/null 2>&1; then
    log_pass "check passes with live WP stack"
else
    log_fail "check failed"
fi

############################################################
# 2. analyze BEFORE
############################################################
az_before=$(run_tool "analyze" 2>&1 || true)
SCORE_BEFORE=$(echo "$az_before" | sed -n 's/.*SCORE: \([0-9]*\)\/100.*/\1/p' | head -1)
if [ -n "$SCORE_BEFORE" ]; then
    log_pass "analyze (before): score ${SCORE_BEFORE}/100"
else
    log_fail "analyze (before) produced no score"
fi

############################################################
# 3. optimize --profile woocommerce
############################################################
opt_out=$(run_tool "optimize --profile woocommerce --force" 2>&1 || true)
if echo "$opt_out" | grep -qE "applied, 0 failed"; then
    log_pass "optimize --profile woocommerce: all features applied"
else
    log_fail "optimize had failures: $(echo "$opt_out" | grep -E 'FAILED|ERROR' | head -3)"
fi
if echo "$opt_out" | grep -qiE "health check passed"; then
    log_pass "post-optimize restart + health check passed"
else
    log_fail "health check failed: $(echo "$opt_out" | grep -i health | head -2)"
fi
if echo "$opt_out" | grep -qi "NO ESI engine"; then
    log_pass "OLS ESI warning surfaced during Woo optimize"
else
    log_note "ESI warning not seen in optimize output"
fi

############################################################
# 4. analyze AFTER
############################################################
az_after=$(run_tool "analyze" 2>&1 || true)
SCORE_AFTER=$(echo "$az_after" | sed -n 's/.*SCORE: \([0-9]*\)\/100.*/\1/p' | head -1)
if [ -n "$SCORE_AFTER" ] && [ -n "$SCORE_BEFORE" ] && [ "$SCORE_AFTER" -gt "$SCORE_BEFORE" ]; then
    log_pass "analyze (after): score improved ${SCORE_BEFORE} -> ${SCORE_AFTER}"
else
    log_fail "score did not improve (${SCORE_BEFORE:-?} -> ${SCORE_AFTER:-?})"
fi

############################################################
# 5. LSCWP option spot-checks (real plugin!)
############################################################
for kv in "cache-ttl_pub 604800" "cache-ttl_priv 1800" "purge-stale 1" "guest_optm 0" "object-life 600" "debug 0"; do
    k=$(echo "$kv" | awk '{print $1}'); want=$(echo "$kv" | awk '{print $2}')
    got=$(wp_in "litespeed-option get $k" 2>/dev/null | tr -d '\r' | tail -1)
    if [ "$got" = "$want" ]; then
        log_pass "LSCWP option ${k} = ${want} (verified on real plugin)"
    else
        log_fail "LSCWP option ${k}: got '${got}', want '${want}'"
    fi
done

############################################################
# 6. Cache correctness from the host
############################################################
sleep 2
curl -s -o /dev/null "$PROD_URL"   # prime
hdr=$(curl -s -D - -o /dev/null "$PROD_URL" | tr -d '\r' | grep -i '^x-litespeed-cache:' || true)
if echo "$hdr" | grep -qi "hit"; then
    log_pass "product page: x-litespeed-cache hit"
else
    log_fail "product page NOT cached (header: '${hdr:-absent}')"
fi

cart_hdr=$(curl -s -D - -o /dev/null "$CART_URL" | tr -d '\r' | grep -i '^x-litespeed-cache:' || true)
if echo "$cart_hdr" | grep -qi "^x-litespeed-cache: *hit"; then
    log_fail "CART PAGE SERVED FROM CACHE: '$cart_hdr' (poisoning risk)"
else
    log_pass "cart page not served from cache (header: '${cart_hdr:-absent}')"
fi

# Two-session cart isolation. The block-based cart page renders client-side,
# so we read carts via the Store API (server-side JSON, cookie-scoped).
# (default permalinks: REST is reachable via ?rest_route=, not /wp-json/)
JAR_A=$(mktemp); JAR_B=$(mktemp)
curl -s -L -c "$JAR_A" -b "$JAR_A" -o /dev/null "${BASE}/?add-to-cart=${PROD_ID}"
cart_a=$(curl -s -L -c "$JAR_A" -b "$JAR_A" "${BASE}/?rest_route=/wc/store/v1/cart")
cart_b=$(curl -s -L -c "$JAR_B" -b "$JAR_B" "${BASE}/?rest_route=/wc/store/v1/cart")
rm -f "$JAR_A" "$JAR_B"
if echo "$cart_a" | grep -q "E2E Widget"; then
    log_pass "session A sees its cart item (Store API)"
    if echo "$cart_b" | grep -q "E2E Widget"; then
        log_fail "SESSION B SEES SESSION A's CART — cache poisoning!"
    else
        log_pass "session B does NOT see session A's cart (isolation OK)"
    fi
else
    log_fail "add-to-cart flow broken (session A cart empty) — isolation untestable"
fi

############################################################
# 7. Redis object cache
############################################################
if in_ols "test -f /usr/local/lsws/Example/html/wp-content/object-cache.php"; then
    log_pass "LSCWP object-cache.php drop-in installed"
else
    log_note "object-cache.php drop-in absent (LSCWP installs it lazily on admin load)"
fi
curl -s -o /dev/null "$PROD_URL"
redis_keys=$(in_ols "redis-cli dbsize" 2>/dev/null | tr -dc '0-9')
if [ -n "$redis_keys" ] && [ "$redis_keys" -gt 0 ]; then
    log_pass "Redis object cache connected (${redis_keys} keys)"
else
    log_fail "Redis has no keys — object cache not connected"
fi

############################################################
# 8. benchmark (from host, against the live store)
############################################################
bench_out=$(LSO_DATA_DIR="$(mktemp -d)" LSO_BENCH_RUNS=6 LSO_BENCH_CART=0 \
    "$ROOT_DIR/litespeed-optimizer.sh" benchmark "$PROD_URL" 2>&1 || true)
TTFB_FIRST=$(echo "$bench_out" | sed -n 's/.*First request TTFB: *\([0-9.]*\) ms.*/\1/p')
TTFB_MEDIAN=$(echo "$bench_out" | sed -n 's/.*Median TTFB (warm): *\([0-9.]*\) ms.*/\1/p')
if [ -n "$TTFB_MEDIAN" ]; then
    log_pass "benchmark: first ${TTFB_FIRST:-?} ms, warm median ${TTFB_MEDIAN} ms"
else
    log_fail "benchmark failed: $(echo "$bench_out" | tail -2)"
fi
if echo "$bench_out" | grep -q "page cache WORKING"; then
    log_pass "benchmark confirms x-litespeed-cache: hit"
else
    log_note "benchmark cache verdict: $(echo "$bench_out" | grep -i x-litespeed | head -1)"
fi

############################################################
# 8b. analyze --remote against the LIVE store (v0.2 feature)
############################################################
rm_out=$(LSO_DATA_DIR="$(mktemp -d)" LSO_REMOTE_DELAY=0 \
    "$ROOT_DIR/litespeed-optimizer.sh" analyze --remote "$BASE/" 2>&1 || true)
RM_SCORE=$(echo "$rm_out" | sed -n 's/.*REMOTE SCORE: \([0-9]*\)\/100.*/\1/p' | head -1)
if [ -n "$RM_SCORE" ]; then
    log_pass "analyze --remote on live store: score ${RM_SCORE}/100"
else
    log_fail "analyze --remote produced no score: $(echo "$rm_out" | tail -3)"
fi
if echo "$rm_out" | grep -q "WooCommerce detected"; then
    log_pass "remote audit auto-detected WooCommerce"
else
    log_fail "remote audit missed WooCommerce"
fi
if echo "$rm_out" | grep -q "two-session cart isolation OK"; then
    log_pass "remote isolation probe confirms no poisoning on live store"
else
    log_fail "remote isolation probe: $(echo "$rm_out" | grep -i isolation | head -1)"
fi
if echo "$rm_out" | grep -q "cart page not cache-served"; then
    log_pass "remote audit confirms cart not cached"
else
    log_fail "remote cart check: $(echo "$rm_out" | grep -i 'cart' | head -1)"
fi

############################################################
# 8c. export-profile import round-trip on the REAL plugin (v0.2 feature)
############################################################
XP_TMP=$(mktemp -d)
"$ROOT_DIR/litespeed-optimizer.sh" export-profile --profile generic --out "$XP_TMP/p.data" >/dev/null 2>&1 || true
if [ -f "$XP_TMP/p.data" ]; then
    # generic differs from the applied woocommerce profile: ttl_frontpage 604800 vs 86400
    docker cp "$XP_TMP/p.data" "$OLS:/tmp/lso-profile.data"
    if wp_in "litespeed-option import /tmp/lso-profile.data" >/dev/null 2>&1; then
        got=$(wp_in "litespeed-option get cache-ttl_frontpage" 2>/dev/null | tr -d '\r' | tail -1)
        if [ "$got" = "604800" ]; then
            log_pass "export-profile .data imports via REAL LSCWP and applies (ttl_frontpage 86400->604800)"
        else
            log_fail "import ran but option not applied (ttl_frontpage='$got')"
        fi
    else
        log_fail "wp litespeed-option import rejected the generated .data file"
    fi
else
    log_fail "export-profile generation failed in E2E"
fi
rm -rf "$XP_TMP"

############################################################
# 9. rollback test
############################################################
BACKUP_TS=$(in_ols "ls -1 /root/.litespeed-optimizer/backups 2>/dev/null | head -1" | tr -d '\r')
if [ -n "$BACKUP_TS" ]; then
    rb_out=$(run_tool "rollback ${BACKUP_TS} --force" 2>&1 || true)
    if echo "$rb_out" | grep -qiE "restored and server verified healthy"; then
        log_pass "rollback ${BACKUP_TS}: restored + server verified healthy"
    else
        log_fail "rollback failed: $(echo "$rb_out" | tail -3)"
    fi
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$BASE/" || echo 000)
    if [ "$code" != "000" ] && [ "${code:0:1}" != "5" ]; then
        log_pass "store still serves HTTP ${code} after rollback"
    else
        log_fail "store unhealthy after rollback (HTTP ${code})"
    fi
else
    log_fail "no backup found to test rollback"
fi

############################################################
# Report
############################################################
mkdir -p "${ROOT_DIR}/docs"
cat > "$REPORT" <<EOF
# E2E Report: WordPress + WooCommerce on OpenLiteSpeed

- **Date**: $(date '+%Y-%m-%d %H:%M:%S')
- **Stack**: ${IMAGE} + ${DB_IMAGE} + Redis (in-container), WordPress + WooCommerce (real installs via wp-cli), lsphp${PHPVER}
- **Tool**: litespeed-optimizer $(grep -m1 '^VERSION=' "$ROOT_DIR/litespeed-optimizer.sh" | cut -d'"' -f2)
- **Result**: ${PASS} passed, ${FAIL} failed

## Scores & timing

| Metric | Value |
|---|---|
| analyze score before optimize | ${SCORE_BEFORE:-n/a}/100 |
| analyze score after optimize | ${SCORE_AFTER:-n/a}/100 |
| First-request TTFB (cache prime) | ${TTFB_FIRST:-n/a} ms |
| Warm median TTFB (5 requests) | ${TTFB_MEDIAN:-n/a} ms |

## Checks

| Status | Check |
|---|---|
${RESULTS}
## Notable findings (from developing this E2E)

1. **Vhost \`rewrite { enable 0 }\` silently breaks LSCWP cookie vary on OLS** —
   LSCWP's vary rules live in the \`# BEGIN LSCACHE\` .htaccess rewrite block; with the
   vhost rewrite engine off they never execute, and a page cached for a cart-holding
   session was served to a fresh session (real cache poisoning, reproduced). The
   \`analyze\` command now flags this as a DANGER finding. Fix: \`rewrite { enable 1,
   autoLoadHtaccess 1 }\` in vhconf.conf.
2. The registered Woo cart page is correctly \`no-cache\` via LSCWP; ad-hoc pages
   containing \`[woocommerce_cart]\` outside the registered cart page are NOT excluded —
   don't duplicate cart shortcodes on cacheable pages.
3. **\`cache-rest = 1\` can serve cached cart JSON** — with REST caching on, the Woo
   Store API cart endpoint (\`?rest_route=/wc/store/v1/cart\`) was served from cache
   to cookieless visitors (order-dependent stale/foreign cart JSON). The
   woocommerce profile now ships \`cache-rest = 0\` and \`analyze --remote\` flags
   cart-API cache hits as DANGER.
4. The Docker image's Example vhost serves \`index.html\` ahead of \`index.php\` —
   WP appears installed (wp-cli works) while HTTP serves the static demo page.

## How to reproduce

\`\`\`bash
tests/e2e-woo.sh   # needs Docker; ~5-10 min
\`\`\`
EOF

echo ""
echo -e "WP+Woo E2E: ${GREEN}PASS: $PASS${NC} ${RED}FAIL: $FAIL${NC}"
echo "Report: $REPORT"
[ "$FAIL" -eq 0 ]
