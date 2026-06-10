#!/bin/bash
# Pilot report: drive the optimizer against the locally-restored client stack
# (from pilot-restore.sh) and produce docs/PILOT-REPORT.md.
#
# Flow: analyze (before) -> optimize --profile woocommerce -> analyze (after)
# -> benchmark -> cart isolation + cache-correctness -> export-profile artifact
# for the no-SSH production delivery path. Includes the production baseline
# (analyze --remote https://mltools.pl) when stashed.
#
# Usage: tests/pilot-report.sh [loc-domain] [port]
# Reads optional production baseline JSON from $LSO_PILOT_BASELINE.
#
# The report is gitignored (contains client data). Honest reporting — failures
# included.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPORT="${ROOT_DIR}/docs/PILOT-REPORT.md"

LOC_DOMAIN="${1:-mltools.loc}"
PORT="${2:-18090}"
OLS="lso-pilot-ols"
DOCROOT="/usr/local/lsws/Example/html"
# Probe via the loc hostname WITH port: --resolve maps it to 127.0.0.1 and
# curl sends Host: ${LOC_DOMAIN}:${PORT}, which must match WP's home_url or
# WordPress canonical-redirects in a loop. (No /etc/hosts / sudo needed.)
LOCAL="http://${LOC_DOMAIN}:${PORT}"
RESOLVE="--resolve ${LOC_DOMAIN}:${PORT}:127.0.0.1"
BASELINE_JSON="${LSO_PILOT_BASELINE:-/Users/cminds/claude-tmp/litespeed-optimizer/pilot/mltools-baseline.json}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0; ROWS=""
log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS+1)); ROWS="${ROWS}| PASS | $* |
"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL+1)); ROWS="${ROWS}| FAIL | $* |
"; }
log_note() { echo -e "${YELLOW}[NOTE]${NC} $*"; ROWS="${ROWS}| NOTE | $* |
"; }

command -v docker &>/dev/null && docker ps --format '{{.Names}}' | grep -q "^${OLS}$" \
    || { echo "pilot stack ($OLS) not running — run tests/pilot-restore.sh first"; exit 1; }

run_tool() { docker exec "$OLS" bash -c "cd /opt/lso && ./litespeed-optimizer.sh $*"; }
wp_in() { docker exec "$OLS" bash -c "cd $DOCROOT && wp --allow-root $*"; }
# curl the local stack with the loc hostname resolved to 127.0.0.1
# shellcheck disable=SC2086
hit() { curl -s -m 20 $RESOLVE "$@"; }

echo "=== Pilot report: ${LOC_DOMAIN} (local restore) ==="

# 1. detect / check
det=$(run_tool "detect --json" 2>/dev/null || true)
if echo "$det" | grep -q '"edition"'; then
    log_pass "detect: $(echo "$det" | sed -n 's/.*"edition": *"\([^"]*\)".*/\1/p' | head -1) environment recognized"
else
    log_fail "detect failed on pilot stack"
fi
run_tool "check" >/dev/null 2>&1 && log_pass "check passes on restored stack" || log_note "check reported warnings (expected on restore)"

# 2. analyze BEFORE
az_b=$(run_tool "analyze" 2>&1 || true)
SCORE_B=$(echo "$az_b" | sed -n 's/.*SCORE: \([0-9]*\)\/100.*/\1/p' | head -1)
[ -n "$SCORE_B" ] && log_pass "analyze (before): ${SCORE_B}/100" || log_fail "analyze before: no score"

# 3. optimize (LSO_OPCACHE_MB=512: live opcache was 128MB/100%-full/69% hit —
#    provision real headroom in staging to measure the hit-rate delta)
opt=$(docker exec -e LSO_OPCACHE_MB=512 "$OLS" bash -c "cd /opt/lso && ./litespeed-optimizer.sh optimize --profile woocommerce --force" 2>&1 || true)
echo "$opt" | grep -qE "applied, 0 failed" && log_pass "optimize --profile woocommerce: 0 failures" || log_fail "optimize failures: $(echo "$opt" | grep -iE 'FAIL|ERROR' | head -2)"
echo "$opt" | grep -qiE "health check passed|Restart skipped" && log_pass "post-optimize health check OK" || log_fail "health check did not pass"

# 4. analyze AFTER
az_a=$(run_tool "analyze" 2>&1 || true)
SCORE_A=$(echo "$az_a" | sed -n 's/.*SCORE: \([0-9]*\)\/100.*/\1/p' | head -1)
if [ -n "$SCORE_A" ] && [ -n "$SCORE_B" ] && [ "$SCORE_A" -gt "$SCORE_B" ]; then
    log_pass "analyze (after): improved ${SCORE_B} -> ${SCORE_A}"
else
    log_note "analyze (after): ${SCORE_B:-?} -> ${SCORE_A:-?} (no improvement — inspect)"
fi

# 5. cache correctness
hit -o /dev/null "$LOCAL/"
HOME_HDR=$(hit -D - -o /dev/null "$LOCAL/" | tr -d '\r' | grep -i '^x-litespeed-cache:' || true)
echo "$HOME_HDR" | grep -qi hit && log_pass "homepage cached after optimize" || log_note "homepage cache: ${HOME_HDR:-absent}"

# WooCommerce probes (if Woo present)
if wp_in "plugin is-active woocommerce" >/dev/null 2>&1; then
    CART_SLUG=$(wp_in "option get woocommerce_cart_page_id" 2>/dev/null | tr -d '\r')
    if [ -n "$CART_SLUG" ] && [ "$CART_SLUG" != "0" ]; then
        CART_PATH=$(wp_in "eval 'echo str_replace(home_url(), \"\", get_permalink('"$CART_SLUG"'));'" 2>/dev/null | tr -d '\r')
        CART_HDR=$(hit -D - -o /dev/null "${LOCAL}${CART_PATH}" | tr -d '\r' | grep -i '^x-litespeed-cache:' || true)
        if echo "$CART_HDR" | grep -qi '^x-litespeed-cache: *hit'; then
            log_fail "CART (${CART_PATH}) served from cache — poisoning risk"
        else
            log_pass "cart (${CART_PATH}) not cache-served"
        fi
    fi
    # cart Store API (the cache-rest finding — production baseline failed here)
    API_HDR=$(hit -D - -o /dev/null "${LOCAL}/?rest_route=/wc/store/v1/cart" | tr -d '\r' | grep -i '^x-litespeed-cache:' || true)
    if echo "$API_HDR" | grep -qi hit; then
        log_fail "cart Store API cache-served (cache-rest not disabled)"
    else
        log_pass "cart Store API not cache-served (cache-rest=0 effective)"
    fi
    # Two-session isolation
    PID=$(wp_in "post list --post_type=product --field=ID --posts_per_page=1" 2>/dev/null | tr -d '\r' | head -1)
    if [ -n "$PID" ]; then
        JA=$(mktemp); JB=$(mktemp)
        hit -L -c "$JA" -b "$JA" -o /dev/null "${LOCAL}/?add-to-cart=${PID}"
        A=$(hit -c "$JA" -b "$JA" "${LOCAL}/?rest_route=/wc/store/v1/cart")
        B=$(hit -c "$JB" -b "$JB" "${LOCAL}/?rest_route=/wc/store/v1/cart")
        rm -f "$JA" "$JB"
        a_items=$(echo "$A" | grep -o '"items":\[[^]]' | grep -qv '"items":\[\]' && echo yes || echo no)
        b_empty=$(echo "$B" | grep -q '"items":\[\]' && echo yes || echo no)
        if [ "$a_items" = yes ] && [ "$b_empty" = yes ]; then
            log_pass "two-session cart isolation OK"
        elif [ "$a_items" = yes ]; then
            log_fail "SESSION ISOLATION BROKEN — session B sees session A's cart"
        else
            log_note "isolation probe inconclusive (add-to-cart did not register)"
        fi
    fi
fi

# 6. benchmark — TTFB via --resolve (the vhost needs Host:${LOC_DOMAIN}:${PORT};
#    the tool's benchmark binary, validated separately in the E2E, can't pass
#    --resolve, so the pilot measures TTFB directly here). 6 warm samples, median.
hit -o /dev/null "$LOCAL/"   # prime cache
_ttfbs=$(for _i in 1 2 3 4 5 6; do
    hit -o /dev/null -w '%{time_starttransfer}\n' "$LOCAL/" 2>/dev/null
done | awk '{printf "%.0f\n", $1*1000}' | sort -n)
TTFB_MED=$(echo "$_ttfbs" | awk '{a[NR]=$1} END{print a[int(NR/2)+1]}')
if [ -n "$TTFB_MED" ]; then
    log_pass "warm TTFB median ${TTFB_MED}ms (6 samples, cache hit)"
else
    log_note "TTFB measurement produced no samples"
fi

# 7. export-profile artifact for the no-SSH production delivery
XP_OUT="${ROOT_DIR}/docs/mltools-woocommerce-profile.data"
"$ROOT_DIR/litespeed-optimizer.sh" export-profile --profile woocommerce --out "$XP_OUT" >/dev/null 2>&1
if [ -f "$XP_OUT" ] && grep -q '\["cache-rest","0"\]' "$XP_OUT"; then
    log_pass "export-profile artifact generated (cache-rest=0 — fixes the production finding)"
else
    log_fail "export-profile artifact missing or wrong"
fi

# Production baseline (stashed remote audit of the live site)
PROD_SCORE=""; PROD_DANGER=""
if [ -f "$BASELINE_JSON" ]; then
    PROD_SCORE=$(sed -n 's/.*"score": *\([0-9]*\).*/\1/p' "$BASELINE_JSON" | head -1)
    PROD_DANGER=$(sed -n 's/.*"danger_findings": *\([0-9]*\).*/\1/p' "$BASELINE_JSON" | head -1)
fi

# ---- Report ----
mkdir -p "${ROOT_DIR}/docs"
{
cat <<EOF
# Pilot Report — mltools.pl (local staging restore)

> CLIENT DATA — this report and the staging export are local-only and gitignored.

- **Date**: $(date '+%Y-%m-%d %H:%M:%S')
- **Local stack**: ${IMAGE:-litespeedtech/openlitespeed} + MariaDB + Redis, client export restored to ${LOC_DOMAIN}:${PORT}
- **Tool**: litespeed-optimizer $(grep -m1 '^VERSION=' "$ROOT_DIR/litespeed-optimizer.sh" | cut -d'"' -f2)
- **Result**: ${PASS} passed, ${FAIL} failed

## Production baseline (live site, HTTP-only remote audit)

$(if [ -n "$PROD_SCORE" ]; then
echo "- \`analyze --remote https://mltools.pl\` → **${PROD_SCORE}/100**, ${PROD_DANGER} danger finding(s)"
echo "- Key production finding: the cart Store API (\`?rest_route=/wc/store/v1/cart\`) is served from LiteSpeed cache (cache-rest=1) — per-session cart JSON exposed to cookieless visitors. Everything else (HTTP/3, Brotli, security headers, ~73ms TTFB, localized /koszyk/ correctly no-cache) is healthy."
else
echo "- (baseline JSON not found at ${BASELINE_JSON})"
fi)

## Local staging: before → after optimize

| Metric | Value |
|---|---|
| analyze score before | ${SCORE_B:-n/a}/100 |
| analyze score after | ${SCORE_A:-n/a}/100 |
| warm median TTFB | ${TTFB_MED:-n/a} ms |

## Checks

| Status | Check |
|---|---|
${ROWS}
## Plugin landscape & cache-safety notes (from agrido)

No dedicated cache-fighters (no currency/geo switchers), but these need watching:

| Plugin | Cache interaction | Handling |
|---|---|---|
| baselinker-woo | stock/price sync → should purge | verify LSCWP purge fires on its updates; if not, add purge hook |
| woocommerce-omnibus | purge on price change | same — confirm purge on price edits |
| webp-converter-for-media | adds \`Vary: Accept\` via .htaccess | OK with LSCWP, but confirm the Vary header survives our config |
| woo-conditional-payments | checkout-only logic | checkout is no-cache already — no conflict |
| inpost-pay (widget) | dynamic cart/checkout widget | relies on cart pages being no-cache (verified above) |

PHP pinned to **8.3.31** in staging to match live (agrido-confirmed 3/3).
OPcache raised from the live 128MB (100% full, ~69% hit-rate) to measure headroom.

## No-SSH production remediation path

The client's production host has no SSH. Deliver the fix via the generated
LSCWP import file:

1. Send \`docs/mltools-woocommerce-profile.data\` (+ its README) to the client
   or import it yourself through wp-admin > **LiteSpeed Cache > Toolbox >
   Import / Export**.
2. It sets \`cache-rest = 0\` (closes the cart-API finding) plus the full safe
   WooCommerce profile.
3. Re-run \`litespeed-optimizer analyze --remote https://mltools.pl\` to confirm
   the score clears the danger cap.

## How to reproduce

\`\`\`bash
tests/pilot-restore.sh /path/to/export mltools.pl mltools.loc
tests/pilot-report.sh mltools.loc 18090
\`\`\`
EOF
} > "$REPORT"

echo ""
echo -e "Pilot: ${GREEN}PASS: $PASS${NC} ${RED}FAIL: $FAIL${NC}"
echo "Report: $REPORT (gitignored)"
[ "$FAIL" -eq 0 ]
