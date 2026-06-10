#!/bin/bash
# Docker integration test: run litespeed-optimizer against a REAL OpenLiteSpeed
# container (litespeedtech/openlitespeed:latest). Skips cleanly when Docker is
# unavailable — same pattern as nginx-optimizer's test-with-nginx.sh.
#
# Validates what fixtures cannot: detect on a live install, real optimize with
# graceful restart + health check, server survives the applied config.
# (LSWS Enterprise cannot be docker-tested freely — fixtures/golden only.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONTAINER="lso-e2e-$$"
IMAGE="litespeedtech/openlitespeed:latest"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0
log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }

if ! command -v docker &>/dev/null || ! docker info >/dev/null 2>&1; then
    echo -e "${YELLOW}[SKIP]${NC} Docker unavailable — E2E is a CI target only"
    exit 0
fi

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "=== Docker OLS E2E ==="
echo "Starting $IMAGE ..."
docker run -d --name "$CONTAINER" -p 18088:8088 "$IMAGE" >/dev/null
sleep 5

# Copy the tool in
docker exec "$CONTAINER" mkdir -p /opt/lso
docker cp "$ROOT_DIR/litespeed-optimizer.sh" "$CONTAINER:/opt/lso/"
docker cp "$ROOT_DIR/lib" "$CONTAINER:/opt/lso/lib"
docker cp "$ROOT_DIR/litespeed-optimizer-lib" "$CONTAINER:/opt/lso/litespeed-optimizer-lib"
docker cp "$ROOT_DIR/templates" "$CONTAINER:/opt/lso/templates"
docker exec "$CONTAINER" bash -c "apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq rsync curl >/dev/null 2>&1 || yum install -y -q rsync curl >/dev/null 2>&1 || true"

run_in() { docker exec "$CONTAINER" bash -c "cd /opt/lso && $*"; }

# 1. detect on a real install
detect_out=$(run_in "./litespeed-optimizer.sh detect --json" 2>/dev/null || true)
if echo "$detect_out" | grep -q '"edition": *"ols"'; then
    log_pass "detect: real container identified as OLS"
else
    log_fail "detect failed on container: $detect_out"
fi

# 2. check
if run_in "./litespeed-optimizer.sh check" >/dev/null 2>&1; then
    log_pass "check passes on container"
else
    log_fail "check failed on container"
fi

# 3. dry-run preview
dry_out=$(run_in "./litespeed-optimizer.sh optimize --profile generic --dry-run" 2>&1 || true)
if echo "$dry_out" | grep -q "\[DRY RUN\] Would set"; then
    log_pass "optimize --dry-run previews on container"
else
    log_fail "optimize --dry-run failed: $(echo "$dry_out" | tail -3)"
fi

# 4. REAL optimize (generic profile: tuning + lsapi + opcache + security)
#    The verified-restart health check is the test: server must come back up.
real_out=$(run_in "./litespeed-optimizer.sh optimize --profile generic --force" 2>&1 || true)
if echo "$real_out" | grep -qE "applied, 0 failed"; then
    log_pass "real optimize applied with 0 failures"
else
    log_fail "real optimize had failures: $(echo "$real_out" | tail -5)"
fi
if echo "$real_out" | grep -qiE "health check passed|Restart skipped"; then
    log_pass "post-optimize health check passed"
else
    log_fail "health check did not pass: $(echo "$real_out" | grep -iE 'health|restart' | tail -3)"
fi

# 5. Server actually answers from the host after optimization
sleep 2
code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:18088/" || echo 000)
if [ "$code" != "000" ] && [ "${code:0:1}" != "5" ]; then
    log_pass "container serves HTTP ${code} after real optimize"
else
    log_fail "container unhealthy after optimize (HTTP ${code})"
fi

# 6. Config grammar still valid + invariant holds on the live config
if run_in "awk '/^extprocessor lsphp/,/^}/' /usr/local/lsws/conf/httpd_config.conf | grep -q maxConns"; then
    mc=$(run_in "awk '/^extprocessor lsphp/,/^}/' /usr/local/lsws/conf/httpd_config.conf | awk '\$1==\"maxConns\"{print \$2}'")
    ch=$(run_in "awk '/^extprocessor lsphp/,/^}/' /usr/local/lsws/conf/httpd_config.conf | grep PHP_LSAPI_CHILDREN | sed 's/.*=//'")
    if [ -n "$mc" ] && [ "$mc" = "$ch" ]; then
        log_pass "live config invariant: maxConns == PHP_LSAPI_CHILDREN ($mc)"
    else
        log_fail "live invariant broken: maxConns=$mc children=$ch"
    fi
else
    log_fail "extprocessor block missing from live config"
fi

echo ""
echo -e "Docker E2E: ${GREEN}PASS: $PASS${NC} ${RED}FAIL: $FAIL${NC}"
[ "$FAIL" -eq 0 ]
