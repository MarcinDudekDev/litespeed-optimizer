#!/bin/bash
# litespeed-optimizer Test Suite
# Mirrors nginx-optimizer's plain-bash harness: static analysis, bash 3.2
# compatibility, portability, functional tests on fixture trees, confedit
# unit tests, backup/rollback round-trip.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIGS_DIR="${SCRIPT_DIR}/configs"
OPTIMIZER="${ROOT_DIR}/litespeed-optimizer.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }
log_skip() { echo -e "${YELLOW}[SKIP]${NC} $*"; SKIP=$((SKIP + 1)); }
log_section() { echo -e "\n${BLUE}=== $* ===${NC}"; }

# Isolated data dir so tests never touch ~/.litespeed-optimizer
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/lso-tests.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
export LSO_DATA_DIR="${TEST_TMP}/data"

ALL_SCRIPTS=(
    "${OPTIMIZER}"
    "${ROOT_DIR}/lib/registry.sh"
    "${ROOT_DIR}/lib/core"/*.sh
    "${ROOT_DIR}/lib/features"/*.sh
    "${ROOT_DIR}/litespeed-optimizer-lib"/*.sh
)

echo "=========================================="
echo "  litespeed-optimizer Test Suite v0.1.0"
echo "=========================================="

################################################################################
# SECTION 1: Static Analysis
################################################################################
log_section "Static Analysis"

if command -v shellcheck &>/dev/null; then
    if shellcheck --severity=error "${ALL_SCRIPTS[@]}" 2>/dev/null; then
        log_pass "Shellcheck (no errors)"
    else
        log_fail "Shellcheck found errors"
    fi

    warning_count=$(shellcheck --severity=warning "${ALL_SCRIPTS[@]}" 2>&1 | grep -c "SC[0-9]" || true)
    warning_count=${warning_count:-0}
    if [ "$warning_count" -eq 0 ]; then
        log_pass "Shellcheck (no warnings)"
    else
        log_skip "Shellcheck has $warning_count warnings (non-blocking)"
    fi
else
    log_skip "Shellcheck not installed"
fi

################################################################################
# SECTION 2: Bash Compatibility
################################################################################
log_section "Bash Compatibility"

for script in "${ALL_SCRIPTS[@]}"; do
    name=$(basename "$script")
    if /bin/bash -n "$script" 2>/dev/null; then
        log_pass "bash -n $name"
    else
        log_fail "bash -n $name"
    fi
done

################################################################################
# SECTION 3: Portability
################################################################################
log_section "Portability Checks"

if grep -rn "find.*-printf" "${ROOT_DIR}/lib" "${ROOT_DIR}/litespeed-optimizer-lib" "${OPTIMIZER}" 2>/dev/null; then
    log_fail "Found GNU-only 'find -printf'"
else
    log_pass "No 'find -printf'"
fi

if grep -rn "declare -A" "${ROOT_DIR}/lib" "${ROOT_DIR}/litespeed-optimizer-lib" "${OPTIMIZER}" 2>/dev/null; then
    log_fail "Found bash 4+ 'declare -A'"
else
    log_pass "No 'declare -A'"
fi

if grep -rn "\bflock\b" "${ROOT_DIR}/lib" "${ROOT_DIR}/litespeed-optimizer-lib" "${OPTIMIZER}" 2>/dev/null | grep -v "^[^:]*:[0-9]*: *#"; then
    log_fail "Found Linux-only 'flock'"
else
    log_pass "No 'flock'"
fi

################################################################################
# SECTION 4: Functional Tests (CLI)
################################################################################
log_section "Functional Tests"

expected_version=$(grep -m1 '^VERSION=' "$OPTIMIZER" | cut -d'"' -f2)
version_output=$("${OPTIMIZER}" --version 2>&1 || true)
if echo "$version_output" | grep -q "$expected_version"; then
    log_pass "--version returns ${expected_version}"
else
    log_fail "--version incorrect: $version_output"
fi

help_output=$("${OPTIMIZER}" help 2>&1 || true)
if echo "$help_output" | grep -q "COMMANDS:"; then
    log_pass "help command works"
else
    log_fail "help command failed"
fi

# Invalid input rejected
bad_output=$("${OPTIMIZER}" detect '../etc/passwd' 2>&1 || true)
if echo "$bad_output" | grep -qi "invalid input"; then
    log_pass "path-traversal input rejected"
else
    log_fail "path-traversal input NOT rejected"
fi

# Unknown feature rejected
feat_output=$("${OPTIMIZER}" optimize --feature bogus 2>&1 || true)
if echo "$feat_output" | grep -qi "unknown feature"; then
    log_pass "unknown --feature rejected"
else
    log_fail "unknown --feature NOT rejected"
fi

# Unknown profile rejected
prof_output=$("${OPTIMIZER}" optimize --profile bogus 2>&1 || true)
if echo "$prof_output" | grep -qi "unknown profile"; then
    log_pass "unknown --profile rejected"
else
    log_fail "unknown --profile NOT rejected"
fi

# rollback --list works (empty)
rb_output=$("${OPTIMIZER}" rollback --list 2>&1 || true)
if echo "$rb_output" | grep -qi "backup"; then
    log_pass "rollback --list works"
else
    log_fail "rollback --list failed"
fi

# rollback rejects bad timestamp
rbts_output=$("${OPTIMIZER}" rollback 99999999-999999x 2>&1 || true)
if echo "$rbts_output" | grep -qiE "invalid (input|backup)"; then
    log_pass "rollback rejects malformed timestamp"
else
    log_fail "rollback accepted malformed timestamp: $rbts_output"
fi

################################################################################
# SECTION 5: Detection Tests (fixture trees)
################################################################################
log_section "Detection Tests"

# detect_fixture <fixture> <expected-edition> <expected-panel>
detect_fixture() {
    local fixture="$1" want_edition="$2" want_panel="$3"
    local out
    out=$(LSO_FS_ROOT="${CONFIGS_DIR}/${fixture}" "${OPTIMIZER}" detect --json 2>/dev/null || true)
    local edition panel
    if command -v jq &>/dev/null; then
        edition=$(echo "$out" | jq -r '.edition' 2>/dev/null || echo "")
        panel=$(echo "$out" | jq -r '.panel' 2>/dev/null || echo "")
    else
        edition=$(echo "$out" | sed -n 's/.*"edition":"\([^"]*\)".*/\1/p')
        panel=$(echo "$out" | sed -n 's/.*"panel":"\([^"]*\)".*/\1/p')
    fi

    if [ "$edition" = "$want_edition" ] && [ "$panel" = "$want_panel" ]; then
        log_pass "detect ${fixture}: ${edition}/${panel}"
    else
        log_fail "detect ${fixture}: got '${edition}/${panel}', want '${want_edition}/${want_panel}'"
    fi
}

detect_fixture "plain-ols"         "ols"        "plain"
detect_fixture "cyberpanel"        "ols"        "cyberpanel"
detect_fixture "cpanel-enterprise" "enterprise" "cpanel"
detect_fixture "directadmin"       "ols"        "directadmin"

# broken-edge: lsws root exists but no main config -> detect must fail cleanly
if LSO_FS_ROOT="${CONFIGS_DIR}/broken-edge" "${OPTIMIZER}" detect 2>/dev/null; then
    log_fail "broken-edge: detect should fail (no main config)"
else
    log_pass "broken-edge: detect fails cleanly"
fi

# Detail assertions on plain-ols
plain_json=$(LSO_FS_ROOT="${CONFIGS_DIR}/plain-ols" "${OPTIMIZER}" detect --json 2>/dev/null || true)
if echo "$plain_json" | grep -q '"main_conf": *"[^"]*httpd_config.conf"'; then
    log_pass "plain-ols: main_conf path resolved"
else
    log_fail "plain-ols: main_conf path wrong: $plain_json"
fi
if echo "$plain_json" | grep -q 'wp-config\|public_html'; then
    log_pass "plain-ols: WP site discovered"
else
    log_fail "plain-ols: WP site NOT discovered"
fi
if echo "$plain_json" | grep -q '"has_redis": *true'; then
    log_pass "plain-ols: redis fixture detected"
else
    log_fail "plain-ols: redis fixture NOT detected"
fi
# issue #1: fixture has lsphp81 (the configured handler) AND lsphp83 (newer,
# installed but unused). Detection must follow the extProcessor handler (8.1),
# NOT the highest installed (8.3) — else we'd tune the wrong PHP (silent no-op).
if echo "$plain_json" | grep -q '"php_ver": *"8.1"'; then
    log_pass "plain-ols: PHP version follows extProcessor handler (8.1, not newer 8.3)"
else
    log_fail "plain-ols: PHP detection picked wrong lsphp (want 8.1 handler, not highest): $plain_json"
fi

# cyberpanel: csf firewall detected
cp_json=$(LSO_FS_ROOT="${CONFIGS_DIR}/cyberpanel" "${OPTIMIZER}" detect --json 2>/dev/null || true)
if echo "$cp_json" | grep -q '"firewall": *"csf"'; then
    log_pass "cyberpanel: csf firewall detected"
else
    log_fail "cyberpanel: csf firewall NOT detected"
fi
if echo "$cp_json" | grep -q '"has_mariadb": *true'; then
    log_pass "cyberpanel: mariadb fixture detected"
else
    log_fail "cyberpanel: mariadb fixture NOT detected"
fi

# cpanel-enterprise: restart cmd is restartsrv_lsws
ce_json=$(LSO_FS_ROOT="${CONFIGS_DIR}/cpanel-enterprise" "${OPTIMIZER}" detect --json 2>/dev/null || true)
if echo "$ce_json" | grep -q 'restartsrv_lsws'; then
    log_pass "cpanel-enterprise: restart cmd = restartsrv_lsws"
else
    log_fail "cpanel-enterprise: restart cmd wrong: $ce_json"
fi
if echo "$ce_json" | grep -q '"main_conf": *"[^"]*httpd_config.xml"'; then
    log_pass "cpanel-enterprise: XML main config"
else
    log_fail "cpanel-enterprise: main config wrong"
fi

# check command runs on fixture
check_output=$(LSO_FS_ROOT="${CONFIGS_DIR}/plain-ols" "${OPTIMIZER}" check 2>&1 || true)
if echo "$check_output" | grep -qi "LiteSpeed found: ols"; then
    log_pass "check command detects fixture environment"
else
    log_fail "check command failed: $check_output"
fi

################################################################################
# SECTION 6: Sysinfo / Sizing Tests
################################################################################
log_section "Sysinfo / Sizing Tests"

# Source libs in a subshell-friendly way for unit tests
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/core/helpers.sh"
# Minimal logger stubs for sourced modules
log_info() { :; }; log_warn() { :; }; log_error() { echo "$@" >&2; }; log_success() { :; }
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/core/sysinfo.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/core/confedit.sh"

# Tier boundaries
t1=$(LSO_RAM_MB=1024 sysinfo_ram_tier)
t2=$(LSO_RAM_MB=2048 sysinfo_ram_tier)
t4=$(LSO_RAM_MB=4096 sysinfo_ram_tier)
t8=$(LSO_RAM_MB=8192 sysinfo_ram_tier)
if [ "$t1" = "1g" ] && [ "$t2" = "2g" ] && [ "$t4" = "4g" ] && [ "$t8" = "8g" ]; then
    log_pass "RAM tiers: 1024->1g 2048->2g 4096->4g 8192->8g"
else
    log_fail "RAM tiers wrong: $t1 $t2 $t4 $t8"
fi

# Tier lookups match SYNTHESIS table
if [ "$(lso_innodb_pool 1024)" = "256" ] && [ "$(lso_innodb_pool 2048)" = "512" ] && \
   [ "$(lso_innodb_pool 4096)" = "1280" ] && [ "$(lso_innodb_pool 8192)" = "2816" ]; then
    log_pass "lso_innodb_pool table values"
else
    log_fail "lso_innodb_pool wrong"
fi
if [ "$(lso_redis_mb 1024)" = "64" ] && [ "$(lso_redis_mb 8192)" = "768" ]; then
    log_pass "lso_redis_mb table values"
else
    log_fail "lso_redis_mb wrong"
fi
if [ "$(lso_avoid_fork 1024)" = "0" ] && [ "$(lso_avoid_fork 2048)" = "200M" ] && \
   [ "$(lso_avoid_fork 4096)" = "500M" ] && [ "$(lso_avoid_fork 8192)" = "1" ]; then
    log_pass "lso_avoid_fork tier values"
else
    log_fail "lso_avoid_fork wrong"
fi

# lso_children: floor of 8 on tiny boxes, CPU cap respected
c_small=$(lso_children 1024 1 80)
c_big=$(lso_children 8192 8 50)
c_cap=$(lso_children 16384 1 50)
if [ "$c_small" = "8" ]; then
    log_pass "lso_children floor=8 on 1GB/1core (got $c_small)"
else
    log_fail "lso_children floor wrong: $c_small"
fi
if [ "$c_cap" = "8" ]; then
    log_pass "lso_children CPU cap cores*8 (16GB/1core -> $c_cap)"
else
    log_fail "lso_children CPU cap wrong: $c_cap"
fi
if [ "$c_big" -gt 8 ] && [ "$c_big" -le 64 ]; then
    log_pass "lso_children 8GB/8core in sane range (got $c_big)"
else
    log_fail "lso_children 8GB/8core out of range: $c_big"
fi

################################################################################
# SECTION 7: confedit Unit Tests
################################################################################
log_section "confedit Unit Tests"

CONF_TEST_DIR="${TEST_TMP}/confedit"
mkdir -p "$CONF_TEST_DIR"
TEST_CONF="${CONF_TEST_DIR}/httpd_config.conf"
cp "${CONFIGS_DIR}/plain-ols/usr/local/lsws/conf/httpd_config.conf" "$TEST_CONF"

# ols_get: existing key in tuning block
val=$(ols_get "$TEST_CONF" tuning maxConnections || echo "FAIL")
if [ "$val" = "2000" ]; then
    log_pass "ols_get tuning.maxConnections = 2000"
else
    log_fail "ols_get tuning.maxConnections: got '$val'"
fi

# ols_get: key in extprocessor block (block with argument)
val=$(ols_get "$TEST_CONF" extprocessor maxConns || echo "FAIL")
if [ "$val" = "10" ]; then
    log_pass "ols_get extprocessor.maxConns = 10"
else
    log_fail "ols_get extprocessor.maxConns: got '$val'"
fi

# ols_get: top-level key (special block "server")
val=$(ols_get "$TEST_CONF" server serverName || echo "FAIL")
if [ "$val" = "example-server" ]; then
    log_pass "ols_get top-level serverName"
else
    log_fail "ols_get top-level serverName: got '$val'"
fi

# ols_get: missing key returns nonzero
if ols_get "$TEST_CONF" tuning noSuchKey >/dev/null 2>&1; then
    log_fail "ols_get missing key should fail"
else
    log_pass "ols_get missing key returns nonzero"
fi

# ols_set: replace existing key
ols_set "$TEST_CONF" tuning maxConnections 10000
val=$(ols_get "$TEST_CONF" tuning maxConnections)
if [ "$val" = "10000" ]; then
    log_pass "ols_set replaces existing key"
else
    log_fail "ols_set replace: got '$val'"
fi

# ols_set must not have touched the same key in OTHER blocks
val=$(ols_get "$TEST_CONF" extprocessor maxConns)
if [ "$val" = "10" ]; then
    log_pass "ols_set scoped to target block only"
else
    log_fail "ols_set leaked into other blocks: extprocessor.maxConns='$val'"
fi

# ols_set: insert new key into existing block
ols_set "$TEST_CONF" tuning gzipAutoUpdateStatic 1
val=$(ols_get "$TEST_CONF" tuning gzipAutoUpdateStatic)
if [ "$val" = "1" ]; then
    log_pass "ols_set inserts new key into existing block"
else
    log_fail "ols_set insert: got '$val'"
fi

# ols_set: create absent block
ols_set "$TEST_CONF" lsrecaptcha enabled 0
val=$(ols_get "$TEST_CONF" lsrecaptcha enabled)
if [ "$val" = "0" ]; then
    log_pass "ols_set creates absent block"
else
    log_fail "ols_set create block: got '$val'"
fi

# Comments preserved through edits
if grep -q "# PLAIN-TEXT CONFIGURATION FILE" "$TEST_CONF"; then
    log_pass "comments preserved through ols_set edits"
else
    log_fail "comments lost after ols_set"
fi

# Config still lints clean after edits
if ols_lint "$TEST_CONF" 2>/dev/null; then
    log_pass "edited config passes ols_lint"
else
    log_fail "edited config fails ols_lint"
fi

# CRLF input handled
CRLF_CONF="${CONF_TEST_DIR}/crlf.conf"
printf 'tuning {\r\n  maxConnections 500\r\n}\r\n' > "$CRLF_CONF"
val=$(ols_get "$CRLF_CONF" tuning maxConnections || echo "FAIL")
if [ "$val" = "500" ]; then
    log_pass "ols_get handles CRLF line endings"
else
    log_fail "ols_get CRLF: got '$val'"
fi
ols_set "$CRLF_CONF" tuning maxConnections 600
val=$(ols_get "$CRLF_CONF" tuning maxConnections || echo "FAIL")
if [ "$val" = "600" ]; then
    log_pass "ols_set handles CRLF line endings"
else
    log_fail "ols_set CRLF: got '$val'"
fi

# Nested blocks: vhost-style config — key inside nested block must not match
NESTED_CONF="${CONF_TEST_DIR}/nested.conf"
cat > "$NESTED_CONF" <<'EOF'
virtualhost example {
  vhRoot /home/example/
  index {
    useServer 0
  }
}
tuning {
  useServer 99
}
EOF
val=$(ols_get "$NESTED_CONF" tuning useServer || echo "FAIL")
if [ "$val" = "99" ]; then
    log_pass "ols_get skips keys in nested sub-blocks"
else
    log_fail "ols_get nested: got '$val'"
fi

# ols_ensure_include: idempotent
INC_CONF="${CONF_TEST_DIR}/inc.conf"
printf 'serverName test\n' > "$INC_CONF"
ols_ensure_include "$INC_CONF" "conf/litespeed-optimizer/tuning.conf"
ols_ensure_include "$INC_CONF" "conf/litespeed-optimizer/tuning.conf"
inc_count=$(grep -c "include conf/litespeed-optimizer/tuning.conf" "$INC_CONF")
if [ "$inc_count" = "1" ]; then
    log_pass "ols_ensure_include is idempotent"
else
    log_fail "ols_ensure_include added $inc_count lines"
fi
ols_remove_include "$INC_CONF" "conf/litespeed-optimizer/tuning.conf"
if grep -q "include conf/litespeed-optimizer" "$INC_CONF"; then
    log_fail "ols_remove_include left include behind"
else
    log_pass "ols_remove_include removes include line"
fi

# ols_lint: catches unbalanced braces
if ols_lint "${CONFIGS_DIR}/broken-edge/usr/local/lsws/conf/broken.conf" 2>/dev/null; then
    log_fail "ols_lint should reject broken.conf"
else
    log_pass "ols_lint rejects unbalanced braces"
fi
if ols_lint "${CONFIGS_DIR}/plain-ols/usr/local/lsws/conf/httpd_config.conf" 2>/dev/null; then
    log_pass "ols_lint accepts valid fixture config"
else
    log_fail "ols_lint rejects valid config"
fi

################################################################################
# SECTION 8: Backup / Rollback Round-Trip
################################################################################
log_section "Backup / Rollback Tests"

# Work on a disposable copy of the plain-ols fixture
BK_FIXTURE="${TEST_TMP}/bk-fixture"
mkdir -p "$BK_FIXTURE"
cp -R "${CONFIGS_DIR}/plain-ols/." "$BK_FIXTURE/"

# Snapshot of pristine state for the final diff
PRISTINE="${TEST_TMP}/pristine"
mkdir -p "$PRISTINE"
cp -R "$BK_FIXTURE/." "$PRISTINE/"

run_backup_env() {
    # Run a command inside a fully-sourced environment pointed at the fixture
    (
        set -euo pipefail
        VERSION="0.1.0-test"
        DATA_DIR="${LSO_DATA_DIR}"
        BACKUP_DIR="${DATA_DIR}/backups"
        LOG_DIR="${DATA_DIR}/logs"
        LOG_FILE="${LOG_DIR}/test.log"
        QUIET=true DRY_RUN=false FORCE=true
        mkdir -p "$BACKUP_DIR" "$LOG_DIR"
        log_info() { :; }; log_warn() { :; }; log_success() { :; }
        log_error() { echo "[ERROR] $*" >&2; }
        export LSO_FS_ROOT="$BK_FIXTURE"
        export LSO_SKIP_RESTART=1
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/core/helpers.sh"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/core/sysinfo.sh"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/core/detect-env.sh"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/core/confedit.sh"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/litespeed-optimizer-lib/backup.sh"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/litespeed-optimizer-lib/validator.sh"
        detect_environment
        "$@"
    )
}

# 1. Create backup
if run_backup_env create_backup "" >/dev/null 2>&1; then
    log_pass "create_backup succeeds on fixture tree"
else
    log_fail "create_backup failed"
fi

backup_ts=$(ls -1 "${LSO_DATA_DIR}/backups" 2>/dev/null | head -1)
if [ -n "$backup_ts" ] && [ -f "${LSO_DATA_DIR}/backups/${backup_ts}/manifest.txt" ]; then
    log_pass "backup manifest.txt created"
else
    log_fail "backup manifest.txt missing"
fi
if [ -f "${LSO_DATA_DIR}/backups/${backup_ts}/lsws-conf/httpd_config.conf" ]; then
    log_pass "backup contains lsws-conf tree"
else
    log_fail "backup missing lsws-conf tree"
fi
if find "${LSO_DATA_DIR}/backups/${backup_ts}/htaccess" -name ".htaccess" 2>/dev/null | grep -q .; then
    log_pass "backup contains site .htaccess"
else
    log_fail "backup missing site .htaccess"
fi

# 2. Corrupt the live config + htaccess
echo "GARBAGE { broken" >> "$BK_FIXTURE/usr/local/lsws/conf/httpd_config.conf"
echo "CORRUPTED" > "$BK_FIXTURE/home/example.com/public_html/.htaccess"
rm -f "$BK_FIXTURE/usr/local/lsws/conf/vhosts/example/vhconf.conf"

# 3. Restore
if run_backup_env restore_backup_files "${LSO_DATA_DIR}/backups/${backup_ts}" >/dev/null 2>&1; then
    log_pass "restore_backup_files succeeds"
else
    log_fail "restore_backup_files failed"
fi
if diff -r "$PRISTINE/usr/local/lsws/conf" "$BK_FIXTURE/usr/local/lsws/conf" >/dev/null 2>&1; then
    log_pass "lsws conf tree identical to pristine after rollback (diff -r)"
else
    log_fail "lsws conf tree differs after rollback"
    diff -r "$PRISTINE/usr/local/lsws/conf" "$BK_FIXTURE/usr/local/lsws/conf" 2>&1 | head -5
fi
if diff "$PRISTINE/home/example.com/public_html/.htaccess" "$BK_FIXTURE/home/example.com/public_html/.htaccess" >/dev/null 2>&1; then
    log_pass ".htaccess restored to pristine"
else
    log_fail ".htaccess differs after rollback"
fi

# 4. Checksum verification reports clean
if run_backup_env verify_restored_files "${LSO_DATA_DIR}/backups/${backup_ts}" >/dev/null 2>&1; then
    log_pass "verify_restored_files passes after restore"
else
    log_fail "verify_restored_files reports mismatches"
fi

################################################################################
# SECTION 9: Transaction Primitives
################################################################################
log_section "Transaction Tests"

TXN_DIR="${TEST_TMP}/txn"
mkdir -p "$TXN_DIR"
echo "original" > "$TXN_DIR/file.conf"

# Commit path
(
    log_error() { echo "$@" >&2; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    transaction_start
    transaction_stage "$TXN_DIR/file.conf"
    echo "modified" > "$TXN_TEMP_FILE"
    transaction_commit
)
if [ "$(cat "$TXN_DIR/file.conf")" = "modified" ]; then
    log_pass "transaction commit applies changes"
else
    log_fail "transaction commit failed"
fi

# Rollback path
(
    log_error() { echo "$@" >&2; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    transaction_start
    transaction_stage "$TXN_DIR/file.conf"
    echo "should-not-appear" > "$TXN_TEMP_FILE"
    transaction_rollback
)
if [ "$(cat "$TXN_DIR/file.conf")" = "modified" ]; then
    log_pass "transaction rollback discards changes"
else
    log_fail "transaction rollback failed"
fi
leftover=$(find "$TXN_DIR" -name ".lso-txn.*" | wc -l | tr -d ' ')
if [ "$leftover" = "0" ]; then
    log_pass "no temp files left after transactions"
else
    log_fail "$leftover temp files left behind"
fi

################################################################################
# SECTION 10: confedit env primitives ("env VAR=value" lines, "name arg" blocks)
################################################################################
log_section "confedit env Primitives"

ENV_CONF="${TEST_TMP}/env.conf"
cp "${CONFIGS_DIR}/plain-ols/usr/local/lsws/conf/httpd_config.conf" "$ENV_CONF"

val=$(ols_get_env "$ENV_CONF" "extprocessor lsphp" PHP_LSAPI_CHILDREN || echo "FAIL")
if [ "$val" = "10" ]; then
    log_pass "ols_get_env reads env line value"
else
    log_fail "ols_get_env: got '$val'"
fi

ols_set_env "$ENV_CONF" "extprocessor lsphp" PHP_LSAPI_CHILDREN 25
ols_set_env "$ENV_CONF" "extprocessor lsphp" LSAPI_NEW_VAR hello
val=$(ols_get_env "$ENV_CONF" "extprocessor lsphp" PHP_LSAPI_CHILDREN || echo "FAIL")
val2=$(ols_get_env "$ENV_CONF" "extprocessor lsphp" LSAPI_NEW_VAR || echo "FAIL")
env_count=$(grep -c "PHP_LSAPI_CHILDREN=" "$ENV_CONF")
if [ "$val" = "25" ] && [ "$val2" = "hello" ] && [ "$env_count" = "1" ]; then
    log_pass "ols_set_env replaces and inserts env lines"
else
    log_fail "ols_set_env: replace='$val' insert='$val2' count=$env_count"
fi

# "name arg" block addressing
val=$(ols_get "$ENV_CONF" "module cache" internal || echo "FAIL")
if [ "$val" = "1" ]; then
    log_pass "ols_get addresses 'module cache' block by name+arg"
else
    log_fail "ols_get 'module cache': got '$val'"
fi
if ols_lint "$ENV_CONF" 2>/dev/null; then
    log_pass "config lints clean after env edits"
else
    log_fail "config broken after env edits"
fi

################################################################################
# SECTION 11: Golden Config Tests (optimize per RAM tier)
################################################################################
log_section "Golden Config Tests"

GOLDEN_DIR="${SCRIPT_DIR}/golden"

# run_golden_tier <ram_mb> <cores> <tier>
run_golden_tier() {
    local ram="$1" cores="$2" tier="$3"
    local fix="${TEST_TMP}/golden-${tier}"
    local data="${TEST_TMP}/golden-data-${tier}"
    mkdir -p "$data"
    cp -R "${CONFIGS_DIR}/plain-ols" "$fix"
    mkdir -p "$fix/etc/php.d"

    # LSO_WP_BIN=/nonexistent: keep golden runs hermetic from any host wp-cli
    if ! LSO_DATA_DIR="$data" LSO_FS_ROOT="$fix" LSO_RAM_MB="$ram" LSO_CORES="$cores" \
         LSO_PHP_INI_SCAN_DIR="$fix/etc/php.d" LSO_SKIP_RESTART=1 LSO_WP_BIN=/nonexistent \
         "${OPTIMIZER}" optimize --force --quiet >/dev/null 2>&1; then
        log_fail "golden ${tier}: optimize failed"
        return
    fi

    local got_conf="$fix/usr/local/lsws/conf/httpd_config.conf"
    local got_ini="$fix/etc/php.d/99-litespeed-optimizer-opcache.ini"

    if diff "${GOLDEN_DIR}/plain-ols-${tier}/httpd_config.conf" "$got_conf" >/dev/null 2>&1; then
        log_pass "golden ${tier}: httpd_config.conf matches"
    else
        log_fail "golden ${tier}: httpd_config.conf differs"
        diff "${GOLDEN_DIR}/plain-ols-${tier}/httpd_config.conf" "$got_conf" 2>&1 | head -5
    fi

    if diff "${GOLDEN_DIR}/plain-ols-${tier}/opcache.ini" "$got_ini" >/dev/null 2>&1; then
        log_pass "golden ${tier}: opcache.ini matches"
    else
        log_fail "golden ${tier}: opcache.ini differs"
    fi

    # Invariant: maxConns == PHP_LSAPI_CHILDREN (explicit assertion per SPEC)
    local maxconns children
    maxconns=$(awk '/^extprocessor lsphp \{/,/^\}/' "$got_conf" | awk '$1=="maxConns" {print $2}')
    children=$(awk '/^extprocessor lsphp \{/,/^\}/' "$got_conf" | grep 'PHP_LSAPI_CHILDREN=' | sed 's/.*=//')
    if [ -n "$maxconns" ] && [ "$maxconns" = "$children" ]; then
        log_pass "golden ${tier}: maxConns == PHP_LSAPI_CHILDREN (${maxconns})"
    else
        log_fail "golden ${tier}: invariant broken: maxConns='$maxconns' children='$children'"
    fi

    # Danger guard: enableCache must be 0 and never 1 at server level
    if grep -E '^[[:space:]]*enableCache[[:space:]]+1' "$got_conf" >/dev/null 2>&1; then
        log_fail "golden ${tier}: enableCache 1 found at server level (DANGER)"
    else
        log_pass "golden ${tier}: no server-level enableCache 1"
    fi
    if awk '/^module cache \{/,/^\}/' "$got_conf" | grep -E 'enableCache[[:space:]]+0' >/dev/null; then
        log_pass "golden ${tier}: module cache enableCache 0 present"
    else
        log_fail "golden ${tier}: module cache enableCache 0 missing"
    fi

    # Config still grammatically valid
    if ols_lint "$got_conf" 2>/dev/null; then
        log_pass "golden ${tier}: result passes ols_lint"
    else
        log_fail "golden ${tier}: result fails ols_lint"
    fi
}

run_golden_tier 1024 1 1g
run_golden_tier 2048 2 2g
run_golden_tier 4096 4 4g
run_golden_tier 8192 8 8g

# Tier-specific spot checks
if grep -q "LSAPI_PGRP_MAX_IDLE" "${GOLDEN_DIR}/plain-ols-1g/httpd_config.conf"; then
    log_fail "1g golden should NOT set LSAPI_PGRP_MAX_IDLE"
else
    log_pass "1g golden omits LSAPI_PGRP_MAX_IDLE (set only >=2GB)"
fi
if grep -q "LSAPI_PGRP_MAX_IDLE=3600" "${GOLDEN_DIR}/plain-ols-4g/httpd_config.conf"; then
    log_pass "4g golden sets LSAPI_PGRP_MAX_IDLE=3600"
else
    log_fail "4g golden missing LSAPI_PGRP_MAX_IDLE"
fi
if grep -q "LSAPI_AVOID_FORK=0" "${GOLDEN_DIR}/plain-ols-1g/httpd_config.conf" && \
   grep -q "LSAPI_AVOID_FORK=200M" "${GOLDEN_DIR}/plain-ols-2g/httpd_config.conf" && \
   grep -q "LSAPI_AVOID_FORK=500M" "${GOLDEN_DIR}/plain-ols-4g/httpd_config.conf" && \
   grep -q "LSAPI_AVOID_FORK=1" "${GOLDEN_DIR}/plain-ols-8g/httpd_config.conf"; then
    log_pass "AVOID_FORK tier progression 0/200M/500M/1"
else
    log_fail "AVOID_FORK tier progression wrong"
fi

################################################################################
# SECTION 12: Dry-Run Safety + Enterprise Read-Only
################################################################################
log_section "Dry-Run / Enterprise Safety"

# --dry-run must not mutate anything
DR_FIX="${TEST_TMP}/dryrun-fix"
DR_DATA="${TEST_TMP}/dryrun-data"
mkdir -p "$DR_DATA"
cp -R "${CONFIGS_DIR}/plain-ols" "$DR_FIX"
mkdir -p "$DR_FIX/etc/php.d"
sum_before=$(file_checksum "$DR_FIX/usr/local/lsws/conf/httpd_config.conf")
dr_out=$(LSO_DATA_DIR="$DR_DATA" LSO_FS_ROOT="$DR_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$DR_FIX/etc/php.d" LSO_SKIP_RESTART=1 LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" optimize --dry-run 2>&1 || true)
sum_after=$(file_checksum "$DR_FIX/usr/local/lsws/conf/httpd_config.conf")
if [ "$sum_before" = "$sum_after" ]; then
    log_pass "--dry-run leaves main config untouched"
else
    log_fail "--dry-run MODIFIED the main config"
fi
if [ ! -f "$DR_FIX/etc/php.d/99-litespeed-optimizer-opcache.ini" ]; then
    log_pass "--dry-run does not deploy opcache ini"
else
    log_fail "--dry-run deployed opcache ini"
fi
if echo "$dr_out" | grep -q "\[DRY RUN\] Would set"; then
    log_pass "--dry-run prints Would-set preview"
else
    log_fail "--dry-run preview output missing"
fi
backup_count=$(ls -1 "$DR_DATA/backups" 2>/dev/null | wc -l | tr -d ' ')
if [ "$backup_count" = "0" ]; then
    log_pass "--dry-run creates no backup"
else
    log_fail "--dry-run created a backup"
fi

# Enterprise: XML never touched; LSPHP_Workers goes to Apache include
ENT_FIX="${TEST_TMP}/ent-fix"
ENT_DATA="${TEST_TMP}/ent-data"
mkdir -p "$ENT_DATA"
cp -R "${CONFIGS_DIR}/cpanel-enterprise" "$ENT_FIX"
mkdir -p "$ENT_FIX/etc/php.d"
xml_before=$(file_checksum "$ENT_FIX/usr/local/lsws/conf/httpd_config.xml")
ent_out=$(LSO_DATA_DIR="$ENT_DATA" LSO_FS_ROOT="$ENT_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$ENT_FIX/etc/php.d" LSO_SKIP_RESTART=1 LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" optimize --force 2>&1 || true)
xml_after=$(file_checksum "$ENT_FIX/usr/local/lsws/conf/httpd_config.xml")
if [ "$xml_before" = "$xml_after" ]; then
    log_pass "Enterprise: httpd_config.xml never modified"
else
    log_fail "Enterprise: httpd_config.xml WAS MODIFIED (forbidden)"
fi
if grep -q "LSPHP_Workers" "$ENT_FIX/etc/apache2/conf.d/includes/pre_main_global.conf" 2>/dev/null; then
    log_pass "Enterprise: LSPHP_Workers written to Apache include"
else
    log_fail "Enterprise: Apache include missing LSPHP_Workers"
fi
if echo "$ent_out" | grep -q "report-only"; then
    log_pass "Enterprise: tuning{} reported, not written"
else
    log_fail "Enterprise: report-only message missing"
fi
if [ -f "$ENT_FIX/etc/php.d/99-litespeed-optimizer-opcache.ini" ]; then
    log_pass "Enterprise: opcache drop-in deployed"
else
    log_fail "Enterprise: opcache drop-in missing"
fi

# Idempotency: second apply on the 4g tree must produce identical config
IDEM_DATA="${TEST_TMP}/idem-data"
mkdir -p "$IDEM_DATA"
idem_fix="${TEST_TMP}/golden-4g"
sum1=$(file_checksum "$idem_fix/usr/local/lsws/conf/httpd_config.conf")
LSO_DATA_DIR="$IDEM_DATA" LSO_FS_ROOT="$idem_fix" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$idem_fix/etc/php.d" LSO_SKIP_RESTART=1 LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" optimize --force --quiet >/dev/null 2>&1 || true
sum2=$(file_checksum "$idem_fix/usr/local/lsws/conf/httpd_config.conf")
if [ "$sum1" = "$sum2" ]; then
    log_pass "optimize is idempotent (second run = no diff)"
else
    log_fail "optimize not idempotent"
fi

# status reports applied features after optimize
status_out=$(LSO_DATA_DIR="$IDEM_DATA" LSO_FS_ROOT="$idem_fix" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$idem_fix/etc/php.d" LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" status 2>&1 || true)
applied_n=$(echo "$status_out" | grep -c "\[applied\]" || true)
if [ "$applied_n" -ge 4 ]; then
    log_pass "status shows 4 features applied after optimize"
else
    log_fail "status applied count wrong: $applied_n"
fi

################################################################################
# SECTION 13: LSCWP / WooCommerce (mock wp-cli — no real WP needed)
################################################################################
log_section "LSCWP / WooCommerce Tests"

# Mock wp-cli: logs every invocation, answers from WP_MOCK_* env vars
MOCK_WP="${TEST_TMP}/bin/wp"
mkdir -p "${TEST_TMP}/bin"
cat > "$MOCK_WP" <<'MOCKEOF'
#!/bin/bash
# wp-cli mock for litespeed-optimizer tests
echo "$@" >> "${WP_MOCK_LOG:-/dev/null}"
args="$*"
case "$args" in
    *"plugin get litespeed-cache --field=version"*)
        if [ "${WP_MOCK_NO_LSCWP:-0}" = "1" ] && [ ! -f "${WP_MOCK_STATE:-/nonexistent}.installed" ]; then
            exit 1
        fi
        echo "${WP_MOCK_LSCWP_VERSION:-6.5.2}"
        exit 0 ;;
    *"plugin install litespeed-cache"*)
        [ -n "${WP_MOCK_STATE:-}" ] && touch "${WP_MOCK_STATE}.installed"
        exit 0 ;;
    *"plugin is-active litespeed-cache"*)
        exit 0 ;;
    *"plugin is-active woocommerce"*)
        exit "${WP_MOCK_NO_WOO:-0}" ;;
    *"plugin is-active"*)
        exit 1 ;;
    *"plugin update litespeed-cache"*)
        exit 0 ;;
    *"option get siteurl"*)
        echo "http://example.test"
        exit 0 ;;
    *"litespeed-option get cache-exc_cookies"*)
        echo "${WP_MOCK_EXC_COOKIES:-}"
        exit 0 ;;
    *"litespeed-option get cache-vary_cookies"*)
        echo "${WP_MOCK_VARY_COOKIES:-}"
        exit 0 ;;
    *"litespeed-option get cache-ttl_pub"*)
        echo "${WP_MOCK_TTL_PUB:-604800}"
        exit 0 ;;
    *"litespeed-option get crawler"*)
        echo "1"
        exit 0 ;;
    *"litespeed-option export"*)
        echo '{"mock":"export"}'
        exit 0 ;;
    *"opcache_get_status"*)
        # analyzer's runtime opcache probe (wp eval). WP_MOCK_OPCACHE:
        #   full = pool 2% free, 69% hit-rate, interned exhausted (the live case)
        #   healthy = plenty of headroom
        if [ "${WP_MOCK_OPCACHE:-healthy}" = "full" ]; then
            echo '{"used":131000000,"free":2000000,"wasted":500000,"hits":690,"misses":310,"hit_rate":69,"interned_free":1024,"keys":18000,"max_keys":20000}'
        elif [ "${WP_MOCK_OPCACHE:-}" = "null" ]; then
            # the real CLI case: opcache.enable_cli=0 -> null memory stats
            echo '{"used":null,"free":null,"wasted":null,"hits":null,"misses":null,"hit_rate":null,"interned_free":null,"keys":null,"max_keys":null}'
        else
            echo '{"used":40000000,"free":228000000,"wasted":100000,"hits":995,"misses":5,"hit_rate":99,"interned_free":8388608,"keys":3000,"max_keys":50000}'
        fi
        exit 0 ;;
    *"eval"*)
        exit 0 ;;
    *)
        exit 0 ;;
esac
MOCKEOF
chmod +x "$MOCK_WP"

# wp_fix_dir <profile> <logfile> — deterministic fixture dir for a run
# (run_wp_optimize is called via $(...), so it cannot export variables)
wp_fix_dir() {
    echo "${TEST_TMP}/wp-$1-$(basename "$2" .log)"
}

# run_wp_optimize <fixture> <profile> <logfile> [extra env as VAR=val ...]
run_wp_optimize() {
    local fixture="$1" profile="$2" wplog="$3"
    shift 3
    local fix
    fix=$(wp_fix_dir "$profile" "$wplog")
    local data="${fix}-data"
    rm -rf "$fix" "$data"
    mkdir -p "$data"
    cp -R "${CONFIGS_DIR}/${fixture}" "$fix"
    mkdir -p "$fix/etc/php.d"
    : > "$wplog"
    env "$@" WP_MOCK_LOG="$wplog" LSO_WP_BIN="$MOCK_WP" \
        LSO_DATA_DIR="$data" LSO_FS_ROOT="$fix" LSO_RAM_MB=4096 LSO_CORES=4 \
        LSO_PHP_INI_SCAN_DIR="$fix/etc/php.d" LSO_SKIP_RESTART=1 \
        "${OPTIMIZER}" optimize --profile "$profile" --force 2>&1
}

# --- WooCommerce profile on OLS ---
WPLOG="${TEST_TMP}/woo-ols.log"
woo_out=$(run_wp_optimize plain-ols woocommerce "$WPLOG" WP_MOCK_NO_WOO=0 || true)

if grep -q "litespeed-option set cache-ttl_pub 604800" "$WPLOG"; then
    log_pass "LSCWP: cache-ttl_pub 604800 applied"
else
    log_fail "LSCWP: cache-ttl_pub not applied"
fi
if grep -q "litespeed-option set cache-ttl_priv 1800" "$WPLOG"; then
    log_pass "LSCWP: cache-ttl_priv 1800 applied"
else
    log_fail "LSCWP: cache-ttl_priv not applied"
fi
if grep -q "litespeed-option set purge-stale 1" "$WPLOG"; then
    log_pass "LSCWP: serve stale ON"
else
    log_fail "LSCWP: serve stale not applied"
fi
if grep -q "litespeed-option set guest_optm 0" "$WPLOG"; then
    log_pass "LSCWP: guest optimization OFF"
else
    log_fail "LSCWP: guest-optm not applied"
fi
for danger_opt in "optm-css_comb 0" "optm-ucss 0" "optm-js_defer 0" "optm-js_comb 0"; do
    if grep -q "litespeed-option set ${danger_opt}" "$WPLOG"; then
        log_pass "LSCWP woo: ${danger_opt} (combine/UCSS/defer off)"
    else
        log_fail "LSCWP woo: ${danger_opt} missing"
    fi
done
if grep -q "litespeed-option set debug 0" "$WPLOG"; then
    log_pass "LSCWP: debug log OFF"
else
    log_fail "LSCWP: debug not disabled"
fi
if grep -q "litespeed-option set crawler-roles " "$WPLOG"; then
    log_pass "LSCWP: crawler role simulation cleared"
else
    log_fail "LSCWP: crawler-roles not cleared"
fi
# Redis present in plain-ols fixture -> object cache wired with lifetime 600
if grep -q "litespeed-option set object 1" "$WPLOG" && \
   grep -q "litespeed-option set object-life 600" "$WPLOG" && \
   grep -q "litespeed-option set object-kind 1" "$WPLOG"; then
    log_pass "LSCWP: Redis object cache wired (lifetime 600)"
else
    log_fail "LSCWP: object cache wiring wrong"
fi
# OLS: ESI must be 0 + warning printed
if grep -q "litespeed-option set esi 1" "$WPLOG"; then
    log_fail "OLS: ESI was enabled (OLS has no ESI engine!)"
else
    log_pass "OLS: ESI not enabled"
fi
if echo "$woo_out" | grep -qi "NO ESI engine"; then
    log_pass "OLS: ESI warning printed with QUIC.cloud fallback"
else
    log_fail "OLS: ESI warning missing"
fi
if grep -q "litespeed-purge all" "$WPLOG"; then
    log_pass "LSCWP: purge all after apply"
else
    log_fail "LSCWP: purge missing"
fi
if grep -q "litespeed-crawler enable" "$WPLOG"; then
    log_pass "Woo: crawler enabled"
else
    log_fail "Woo: crawler not enabled"
fi
# .log access block in site .htaccess
if grep -q "RewriteRule \\\\.log" "$(wp_fix_dir woocommerce "$WPLOG")/home/example.com/public_html/.htaccess" 2>/dev/null; then
    log_pass "Hardening: *.log access blocked via rewrite in .htaccess"
else
    log_fail "Hardening: .log block missing in .htaccess"
fi

# --- ESI ON for Enterprise ---
WPLOG_ENT="${TEST_TMP}/woo-ent.log"
ent_out=$(run_wp_optimize cpanel-enterprise woocommerce "$WPLOG_ENT" WP_MOCK_NO_WOO=0 || true)
if grep -q "litespeed-option set esi 1" "$WPLOG_ENT" && \
   grep -q "litespeed-option set esi-cache_admbar 1" "$WPLOG_ENT"; then
    log_pass "Enterprise: ESI + admin-bar hole punching enabled"
else
    log_fail "Enterprise: ESI not enabled"
fi

# --- Vary-cookie danger check ---
WPLOG_VARY="${TEST_TMP}/woo-vary.log"
vary_out=$(run_wp_optimize plain-ols woocommerce "$WPLOG_VARY" \
    WP_MOCK_NO_WOO=0 WP_MOCK_EXC_COOKIES="woocommerce_cart_hash;woocommerce_items_in_cart" || true)
if echo "$vary_out" | grep -q "woocommerce_items_in_cart found in Do-Not-Cache"; then
    log_pass "Danger check: items_in_cart in do-not-cache cookies flagged"
else
    log_fail "Danger check: items_in_cart misconfig NOT flagged"
fi

# --- CVE version gate ---
WPLOG_CVE="${TEST_TMP}/woo-cve.log"
cve_out=$(run_wp_optimize plain-ols wordpress "$WPLOG_CVE" WP_MOCK_LSCWP_VERSION=6.3.0 || true)
if echo "$cve_out" | grep -q "CVE-2024-28000"; then
    log_pass "CVE gate: old LSCWP version flagged"
else
    log_fail "CVE gate: old version NOT flagged"
fi
if grep -q "plugin update litespeed-cache" "$WPLOG_CVE"; then
    log_pass "CVE gate: plugin update attempted"
else
    log_fail "CVE gate: no update attempted"
fi

# --- Plugin install when missing ---
WPLOG_INST="${TEST_TMP}/woo-inst.log"
inst_out=$(run_wp_optimize plain-ols wordpress "$WPLOG_INST" \
    WP_MOCK_NO_LSCWP=1 WP_MOCK_STATE="${TEST_TMP}/instate" || true)
if grep -q "plugin install litespeed-cache --activate" "$WPLOG_INST"; then
    log_pass "LSCWP installed+activated when missing"
else
    log_fail "LSCWP install not attempted"
fi

# --- Option export backup before changes ---
if grep -q "litespeed-option export" "$WPLOG"; then
    log_pass "LSCWP options exported before profile apply"
else
    log_fail "LSCWP export backup missing"
fi

# --- Dry-run: no mutating wp calls ---
DR3_FIX="${TEST_TMP}/wp-dryrun"
DR3_DATA="${TEST_TMP}/wp-dryrun-data"
rm -rf "$DR3_FIX" "$DR3_DATA"
mkdir -p "$DR3_DATA"
cp -R "${CONFIGS_DIR}/plain-ols" "$DR3_FIX"
mkdir -p "$DR3_FIX/etc/php.d"
WPLOG_DR="${TEST_TMP}/woo-dr.log"
: > "$WPLOG_DR"
WP_MOCK_LOG="$WPLOG_DR" LSO_WP_BIN="$MOCK_WP" \
    LSO_DATA_DIR="$DR3_DATA" LSO_FS_ROOT="$DR3_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$DR3_FIX/etc/php.d" LSO_SKIP_RESTART=1 \
    "${OPTIMIZER}" optimize --profile woocommerce --dry-run >/dev/null 2>&1 || true
if grep -qE "litespeed-option set|plugin install|plugin update|litespeed-purge" "$WPLOG_DR"; then
    log_fail "--dry-run made mutating wp-cli calls"
else
    log_pass "--dry-run makes no mutating wp-cli calls"
fi
ht_count=$(grep -c "litespeed-optimizer logblock" "$DR3_FIX/home/example.com/public_html/.htaccess" 2>/dev/null || true)
if [ "${ht_count:-0}" = "0" ]; then
    log_pass "--dry-run leaves .htaccess untouched"
else
    log_fail "--dry-run modified .htaccess"
fi

# --- Golden profile payloads (rendered with fixed placeholder values) ---
log_section "Golden Profile Payloads"
GOLDEN_LSCWP="${GOLDEN_DIR}/lscwp"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/core/templates.sh"
for prof in woocommerce wordpress generic; do
    rendered="${TEST_TMP}/profile-${prof}.rendered"
    template_render "${ROOT_DIR}/templates/lscwp/profile-${prof}.txt" \
        "OBJECT=1" "OBJECT_HOST=127.0.0.1" "OBJECT_PORT=6379" \
        "ESI=0" "CACHE_PRIV=0" "SITEMAP=http://example.test/wp-sitemap.xml" \
        > "$rendered"
    if [ -f "${GOLDEN_LSCWP}/profile-${prof}.txt" ]; then
        if diff "${GOLDEN_LSCWP}/profile-${prof}.txt" "$rendered" >/dev/null 2>&1; then
            log_pass "golden profile ${prof}: payload matches"
        else
            log_fail "golden profile ${prof}: payload differs"
            diff "${GOLDEN_LSCWP}/profile-${prof}.txt" "$rendered" | head -5
        fi
    else
        log_fail "golden profile ${prof}: golden file missing"
    fi
    if grep -q "@" "$rendered"; then
        log_fail "golden profile ${prof}: unrendered @PLACEHOLDER@ left"
    else
        log_pass "golden profile ${prof}: all placeholders rendered"
    fi
done
# Safety invariants across ALL profiles
for prof in woocommerce wordpress generic; do
    p="${ROOT_DIR}/templates/lscwp/profile-${prof}.txt"
    if grep -qE "^guest_optm *= *0" "$p" && grep -qE "^optm-ucss *= *0" "$p" && \
       grep -qE "^optm-css_comb *= *0" "$p" && grep -qE "^optm-js_defer *= *0" "$p" && \
       grep -qE "^debug *= *0" "$p" && grep -qE "^object-life *= *600" "$p" && \
       grep -qE "^purge-stale *= *1" "$p"; then
        log_pass "profile ${prof}: safety invariants (no combine/UCSS/defer/guest-optm, stale on, obj-life 600)"
    else
        log_fail "profile ${prof}: safety invariant violated"
    fi
done
# issue #5: Guest Mode must be OFF on the WooCommerce profile (breaks add-to-cart;
# OLS has no ESI to hole-punch the cart). Confirmed in live Woo E2E.
WOO_PROFILE="${ROOT_DIR}/templates/lscwp/profile-woocommerce.txt"
if grep -qE "^guest *= *0" "$WOO_PROFILE"; then
    log_pass "profile woocommerce: Guest Mode OFF (guest=0, shop-safe)"
else
    log_fail "profile woocommerce: Guest Mode must be OFF on shops (guest=0)"
fi
# issue #3: the `object` enable toggle must be applied AFTER object-host/port.
# LSCWP validates the Redis connection at enable-time; enabling before host/port
# are stored hits a fatal in object-cache.cls.php and silently fails to enable.
for prof in woocommerce wordpress generic; do
    p="${ROOT_DIR}/templates/lscwp/profile-${prof}.txt"
    en_line=$(grep -nE "^object *=" "$p" | head -1 | cut -d: -f1)
    host_line=$(grep -nE "^object-host *=" "$p" | head -1 | cut -d: -f1)
    port_line=$(grep -nE "^object-port *=" "$p" | head -1 | cut -d: -f1)
    if [ -n "$en_line" ] && [ -n "$host_line" ] && [ -n "$port_line" ] \
       && [ "$en_line" -gt "$host_line" ] && [ "$en_line" -gt "$port_line" ]; then
        log_pass "profile ${prof}: object enable applied after host/port (issue #3)"
    else
        log_fail "profile ${prof}: object enable must come after object-host/port (en=$en_line host=$host_line port=$port_line)"
    fi
done

################################################################################
# SECTION 14: LSCWP Option-Key Lint (profiles vs vendored plugin key list)
################################################################################
log_section "LSCWP Option-Key Lint"

KEYLIST="${SCRIPT_DIR}/fixtures/lscwp-option-keys-7.8.1.txt"
if [ -f "$KEYLIST" ]; then
    unknown=0
    for prof in "${ROOT_DIR}/templates/lscwp"/profile-*.txt; do
        while IFS= read -r k; do
            [ -z "$k" ] && continue
            if ! grep -qx "$k" "$KEYLIST"; then
                log_fail "$(basename "$prof"): unknown LSCWP key '$k'"
                unknown=$((unknown + 1))
            fi
        done < <(grep -vE '^#|^$' "$prof" | awk -F' *= *' '{print $1}' | sed 's/ *$//')
    done
    if [ "$unknown" -eq 0 ]; then
        log_pass "all profile keys exist in LSCWP 7.8.1 (vendored key list)"
    fi
else
    log_fail "vendored key list missing: $KEYLIST"
fi

################################################################################
# SECTION 15: Security Feature
################################################################################
log_section "Security Feature Tests"

SEC_FIX="${TEST_TMP}/sec-fix"
SEC_DATA="${TEST_TMP}/sec-data"
mkdir -p "$SEC_DATA"
cp -R "${CONFIGS_DIR}/plain-ols" "$SEC_FIX"
mkdir -p "$SEC_FIX/etc/php.d"
sec_out=$(LSO_DATA_DIR="$SEC_DATA" LSO_FS_ROOT="$SEC_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$SEC_FIX/etc/php.d" LSO_SKIP_RESTART=1 LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" optimize --feature security --force 2>&1 || true)

SEC_CONF="$SEC_FIX/usr/local/lsws/conf/httpd_config.conf"
sec_block=$(awk '/^perClientConnLimit \{/,/^\}/' "$SEC_CONF")
sec_ok=true
for kv in "dynReqPerSec 2" "staticReqPerSec 40" "softLimit 15" "hardLimit 20" "gracePeriod 15" "banPeriod 300" "blockBadReq 1"; do
    if ! echo "$sec_block" | grep -qE "$(echo "$kv" | awk '{print $1}')[[:space:]]+$(echo "$kv" | awk '{print $2}')\$"; then
        log_fail "security: $kv not set"
        sec_ok=false
    fi
done
[ "$sec_ok" = true ] && log_pass "security: full perClientConnLimit throttling block applied"
if echo "$sec_out" | grep -qi "recaptcha"; then
    log_pass "security: reCAPTCHA report-only guidance printed"
else
    log_fail "security: reCAPTCHA guidance missing"
fi
if echo "$sec_out" | grep -qi "ModSecurity 3.x ONLY"; then
    log_pass "security: ModSec 3.x-only note printed for OLS"
else
    log_fail "security: ModSec note missing"
fi

# Enterprise: WordPressProtect via include
SEC_ENT_FIX="${TEST_TMP}/sec-ent-fix"
SEC_ENT_DATA="${TEST_TMP}/sec-ent-data"
mkdir -p "$SEC_ENT_DATA"
cp -R "${CONFIGS_DIR}/cpanel-enterprise" "$SEC_ENT_FIX"
mkdir -p "$SEC_ENT_FIX/etc/php.d"
LSO_DATA_DIR="$SEC_ENT_DATA" LSO_FS_ROOT="$SEC_ENT_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$SEC_ENT_FIX/etc/php.d" LSO_SKIP_RESTART=1 LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" optimize --feature security --force >/dev/null 2>&1 || true
if grep -q "WordPressProtect drop, 10" "$SEC_ENT_FIX/etc/apache2/conf.d/includes/pre_main_global.conf" 2>/dev/null; then
    log_pass "security: WordPressProtect written on Enterprise"
else
    log_fail "security: WordPressProtect missing on Enterprise"
fi

################################################################################
# SECTION 16: Analyze (scored audit)
################################################################################
log_section "Analyze Tests"

# Untuned fixture -> low score with FIX hints
AZ_FIX="${TEST_TMP}/az-fix"
AZ_DATA="${TEST_TMP}/az-data"
mkdir -p "$AZ_DATA"
cp -R "${CONFIGS_DIR}/plain-ols" "$AZ_FIX"
mkdir -p "$AZ_FIX/etc/php.d"
az_before=$(LSO_DATA_DIR="$AZ_DATA" LSO_FS_ROOT="$AZ_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$AZ_FIX/etc/php.d" LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" analyze 2>&1 || true)
score_before=$(echo "$az_before" | sed -n 's/.*SCORE: \([0-9]*\)\/100.*/\1/p' | head -1)
if [ -n "$score_before" ]; then
    log_pass "analyze produces a score on untuned box (${score_before}/100)"
else
    log_fail "analyze produced no score: $(echo "$az_before" | tail -3)"
fi
if echo "$az_before" | grep -q "FIX:"; then
    log_pass "analyze prints FIX hints"
else
    log_fail "analyze FIX hints missing"
fi

# Optimize, then analyze again -> score must improve
LSO_DATA_DIR="$AZ_DATA" LSO_FS_ROOT="$AZ_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$AZ_FIX/etc/php.d" LSO_SKIP_RESTART=1 LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" optimize --force --quiet >/dev/null 2>&1 || true
az_after=$(LSO_DATA_DIR="$AZ_DATA" LSO_FS_ROOT="$AZ_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$AZ_FIX/etc/php.d" LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" analyze 2>&1 || true)
score_after=$(echo "$az_after" | sed -n 's/.*SCORE: \([0-9]*\)\/100.*/\1/p' | head -1)
if [ -n "$score_before" ] && [ -n "$score_after" ] && [ "$score_after" -gt "$score_before" ]; then
    log_pass "score improves after optimize (${score_before} -> ${score_after})"
else
    log_fail "score did not improve (${score_before:-?} -> ${score_after:-?})"
fi
if [ -n "$score_after" ] && [ "$score_after" -ge 90 ]; then
    log_pass "tuned box scores >= 90 (${score_after})"
else
    log_fail "tuned box scores below 90 (${score_after:-?})"
fi

# Danger finding caps score at 59: force enableCache 1 server-wide
DANGER_CONF="$AZ_FIX/usr/local/lsws/conf/httpd_config.conf"
perl -pi -e 's/(enableCache\s+)0/${1}1/ if /enableCache/' "$DANGER_CONF"
az_danger=$(LSO_DATA_DIR="$AZ_DATA" LSO_FS_ROOT="$AZ_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$AZ_FIX/etc/php.d" LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" analyze 2>&1 || true)
score_danger=$(echo "$az_danger" | sed -n 's/.*SCORE: \([0-9]*\)\/100.*/\1/p' | head -1)
if [ -n "$score_danger" ] && [ "$score_danger" -le 59 ] && echo "$az_danger" | grep -q "DANGER"; then
    log_pass "enableCache 1 danger finding caps score at 59 (got ${score_danger})"
else
    log_fail "danger cap not applied (score ${score_danger:-?})"
fi

# issue #2: analyze must flag a WP docroot whose .htaccess is missing (pretty
# permalinks 404 + LSCWP cache/vary rules have nowhere to live).
AZ_NOHT="${TEST_TMP}/az-noht"
cp -R "${CONFIGS_DIR}/plain-ols" "$AZ_NOHT"
rm -f "$AZ_NOHT/home/example.com/public_html/.htaccess"
az_noht=$(LSO_DATA_DIR="$AZ_DATA" LSO_FS_ROOT="$AZ_NOHT" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$AZ_NOHT/etc/php.d" LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" analyze 2>&1 || true)
if echo "$az_noht" | grep -q "WP .htaccess missing"; then
    log_pass "analyze flags missing WP .htaccess (issue #2)"
else
    log_fail "analyze did not flag missing WP .htaccess"
fi

# analyze --json structure
az_json=$(LSO_DATA_DIR="$AZ_DATA" LSO_FS_ROOT="$AZ_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$AZ_FIX/etc/php.d" LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" analyze --json 2>/dev/null || true)
if echo "$az_json" | grep -q '"score":' && echo "$az_json" | grep -q '"checks":'; then
    log_pass "analyze --json outputs score + checks array"
else
    log_fail "analyze --json malformed"
fi

################################################################################
# SECTION 17: Benchmark (local test server)
################################################################################
log_section "Benchmark Tests"

if command -v python3 &>/dev/null; then
    BENCH_PORT=18913
    python3 - "$BENCH_PORT" <<'PYEOF' &
import sys, http.server
class H(http.server.BaseHTTPRequestHandler):
    def _r(self):
        self.send_response(200)
        self.send_header("x-litespeed-cache", "hit")
        self.send_header("Content-Type", "text/html")
        self.end_headers()
    def do_GET(self):
        self._r()
        self.wfile.write(b"ok")
    def do_HEAD(self):
        self._r()
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF
    BENCH_PID=$!
    sleep 1

    bench_out=$(LSO_BENCH_RUNS=4 LSO_BENCH_CART=0 \
        "${OPTIMIZER}" benchmark "http://127.0.0.1:${BENCH_PORT}/" 2>&1 || true)
    kill "$BENCH_PID" 2>/dev/null || true

    if echo "$bench_out" | grep -q "Median TTFB"; then
        log_pass "benchmark reports median TTFB"
    else
        log_fail "benchmark median missing: $(echo "$bench_out" | tail -3)"
    fi
    if echo "$bench_out" | grep -q "page cache WORKING"; then
        log_pass "benchmark verifies x-litespeed-cache: hit"
    else
        log_fail "benchmark cache-hit verification failed"
    fi
    if ls "${LSO_DATA_DIR}/benchmarks"/*.json >/dev/null 2>&1; then
        log_pass "benchmark persists JSON result"
    else
        log_fail "benchmark JSON result missing"
    fi
else
    log_skip "python3 unavailable — benchmark live test skipped"
fi

# Unreachable URL fails gracefully
bench_bad=$("${OPTIMIZER}" benchmark "http://127.0.0.1:1/" 2>&1 || true)
if echo "$bench_bad" | grep -qiE "failed|reachable"; then
    log_pass "benchmark fails gracefully on unreachable URL"
else
    log_fail "benchmark bad-URL handling wrong"
fi

################################################################################
# SECTION 18: Remote Analyzer (mock LiteSpeed site)
################################################################################
log_section "Remote Analyzer Tests"

if command -v python3 &>/dev/null; then
    RM_PORT=18914
    # Mock site: argv[2]="good" = well-configured LiteSpeed+Woo store;
    # "bad" = no security headers, cart served as cache HIT, vary broken.
    python3 - "$RM_PORT" "good" <<'PYEOF' &
import sys, json, http.server
MODE = sys.argv[2]
hits = {}
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        path = self.path
        body = b"<html>ok</html>"
        hdrs = {"Server": "LiteSpeed", "Content-Type": "text/html"}
        cookie = self.headers.get("Cookie", "")
        if MODE == "good":
            hdrs["alt-svc"] = 'h3=":443"; ma=2592000'
            hdrs["x-content-type-options"] = "nosniff"
            hdrs["x-frame-options"] = "SAMEORIGIN"
            hdrs["referrer-policy"] = "strict-origin-when-cross-origin"
            hdrs["cache-control"] = "max-age=604800, public"
            if "br" in self.headers.get("Accept-Encoding", ""):
                hdrs["content-encoding"] = "br"
        if "rest_route=/wc/store/v1/products" in path:
            hdrs["Content-Type"] = "application/json"
            body = json.dumps([{"id":10,"name":"Mock Widget",
                "permalink":f"http://127.0.0.1:{sys.argv[1]}/?product=mock-widget"}], separators=(",", ":")).encode()
        elif "rest_route=/wc/store/v1/cart" in path:
            hdrs["Content-Type"] = "application/json"
            hdrs["x-litespeed-cache-control"] = "no-cache"
            if MODE == "bad":
                hdrs["x-litespeed-cache"] = "hit"
                body = json.dumps({"items": [{"name": "Mock Widget"}]}, separators=(",", ":")).encode()
            else:
                items = [{"name": "Mock Widget"}] if "cart=1" in cookie else []
                body = json.dumps({"items": items}, separators=(",", ":")).encode()
        elif "add-to-cart=" in path:
            hdrs["x-litespeed-cache-control"] = "no-cache"
            hdrs["Set-Cookie"] = "cart=1; path=/"
        elif "/cart/" in path or "/checkout/" in path or "wc-ajax" in path:
            if MODE == "bad":
                hdrs["x-litespeed-cache"] = "hit"
            else:
                hdrs["x-litespeed-cache-control"] = "no-cache"
        else:
            # cacheable pages: miss first, hit afterwards (per path)
            body = b"<html class=woocommerce>store</html>"
            n = hits.get(path, 0)
            hits[path] = n + 1
            hdrs["x-litespeed-cache"] = "hit" if n > 0 else "miss"
        self.send_response(200)
        for k, v in hdrs.items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF
    RM_PID=$!
    sleep 1

    rm_out=$(LSO_REMOTE_DELAY=0 "${OPTIMIZER}" analyze --remote "http://127.0.0.1:${RM_PORT}/" 2>&1 || true)
    kill "$RM_PID" 2>/dev/null || true

    rm_score=$(echo "$rm_out" | sed -n 's/.*REMOTE SCORE: \([0-9]*\)\/100.*/\1/p' | head -1)
    if [ -n "$rm_score" ] && [ "$rm_score" -ge 85 ]; then
        log_pass "remote analyze: good mock site scores >= 85 (${rm_score})"
    else
        log_fail "remote analyze good-site score wrong: ${rm_score:-none}: $(echo "$rm_out" | tail -3)"
    fi
    if echo "$rm_out" | grep -q "homepage cached"; then
        log_pass "remote: repeat-request cache hit detected"
    else
        log_fail "remote: cache hit not detected"
    fi
    if echo "$rm_out" | grep -q "HTTP/3 advertised"; then
        log_pass "remote: alt-svc h3 detected"
    else
        log_fail "remote: HTTP/3 not detected"
    fi
    if echo "$rm_out" | grep -q "Brotli compression active"; then
        log_pass "remote: brotli detected"
    else
        log_fail "remote: brotli not detected"
    fi
    if echo "$rm_out" | grep -q "product page cached"; then
        log_pass "remote: Woo product probe works"
    else
        log_fail "remote: product probe failed"
    fi
    if echo "$rm_out" | grep -q "two-session cart isolation OK"; then
        log_pass "remote: isolation probe works (A has item, B clean)"
    else
        log_fail "remote: isolation probe failed: $(echo "$rm_out" | grep -i isolation | head -1)"
    fi

    # Bad site: cart cached + vary-poisoning signature must produce DANGER + cap
    python3 - "$RM_PORT" "bad" <<'PYEOF' &
import sys, json, http.server
MODE = sys.argv[2]
hits = {}
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        path = self.path
        body = b"<html class=woocommerce>store</html>"
        hdrs = {"Server": "LiteSpeed", "Content-Type": "text/html"}
        if "rest_route=/wc/store/v1/products" in path:
            hdrs["Content-Type"] = "application/json"
            body = json.dumps([{"id":10,"name":"Mock Widget",
                "permalink":f"http://127.0.0.1:{sys.argv[1]}/?product=mock-widget"}], separators=(",", ":")).encode()
        elif "rest_route=/wc/store/v1/cart" in path:
            hdrs["Content-Type"] = "application/json"
            hdrs["x-litespeed-cache-control"] = "no-cache"
            hdrs["x-litespeed-cache"] = "hit"
            body = json.dumps({"items": [{"name": "Mock Widget"}]}, separators=(",", ":")).encode()
        elif "add-to-cart=" in path:
            hdrs["Set-Cookie"] = "cart=1; path=/"
        elif "/cart/" in path or "/checkout/" in path or "wc-ajax" in path:
            hdrs["x-litespeed-cache"] = "hit"
        else:
            n = hits.get(path, 0)
            hits[path] = n + 1
            hdrs["x-litespeed-cache"] = "hit" if n > 0 else "miss"
        self.send_response(200)
        for k, v in hdrs.items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF
    RM_PID=$!
    sleep 1
    rm_bad=$(LSO_REMOTE_DELAY=0 "${OPTIMIZER}" analyze --remote "http://127.0.0.1:${RM_PORT}/" 2>&1 || true)
    kill "$RM_PID" 2>/dev/null || true

    bad_score=$(echo "$rm_bad" | sed -n 's/.*REMOTE SCORE: \([0-9]*\)\/100.*/\1/p' | head -1)
    if echo "$rm_bad" | grep -q "served from cache"; then
        log_pass "remote bad-site: cached cart flagged as DANGER"
    else
        log_fail "remote bad-site: cached cart NOT flagged"
    fi
    if echo "$rm_bad" | grep -q "no-cache + HIT"; then
        log_pass "remote bad-site: vary-poisoning signature detected"
    else
        log_fail "remote bad-site: poisoning signature missed"
    fi
    if [ -n "$bad_score" ] && [ "$bad_score" -le 59 ]; then
        log_pass "remote bad-site: danger caps score at 59 (got ${bad_score})"
    else
        log_fail "remote bad-site: cap not applied (${bad_score:-none})"
    fi

    # JSON output
    python3 - "$RM_PORT" "good" <<'PYEOF' &
import sys, http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<html>ok</html>"
        self.send_response(200)
        self.send_header("Server", "LiteSpeed")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF
    RM_PID=$!
    sleep 1
    rm_json=$(LSO_REMOTE_DELAY=0 "${OPTIMIZER}" analyze --remote "http://127.0.0.1:${RM_PORT}/" --json 2>/dev/null || true)
    kill "$RM_PID" 2>/dev/null || true
    if echo "$rm_json" | grep -q '"command": *"analyze-remote"' && echo "$rm_json" | grep -q '"requests_used"'; then
        log_pass "remote analyze --json structure OK"
    else
        log_fail "remote analyze --json malformed"
    fi

    # UA + request cap sanity (from JSON requests_used)
    used=$(echo "$rm_json" | sed -n 's/.*"requests_used": *\([0-9]*\).*/\1/p' | head -1)
    if [ -n "$used" ] && [ "$used" -le 25 ]; then
        log_pass "remote analyze respects request cap (used ${used} <= 25)"
    else
        log_fail "remote request count suspicious: ${used:-none}"
    fi
else
    log_skip "python3 unavailable — remote analyzer tests skipped"
fi

# Bad URL rejected
rm_badurl=$("${OPTIMIZER}" analyze --remote "not-a-url" 2>&1 || true)
if echo "$rm_badurl" | grep -qiE "invalid|requires a full URL"; then
    log_pass "analyze --remote rejects non-URL input"
else
    log_fail "analyze --remote accepted bad input"
fi

################################################################################
# SECTION 19: export-profile (LSCWP .data import format)
################################################################################
log_section "Export-Profile Tests"

XP_DIR="${TEST_TMP}/export"
mkdir -p "$XP_DIR"

for prof in woocommerce wordpress generic; do
    out="${XP_DIR}/p-${prof}.data"
    if "${OPTIMIZER}" export-profile --profile "$prof" --out "$out" >/dev/null 2>&1 && [ -f "$out" ]; then
        log_pass "export-profile ${prof}: file generated"
    else
        log_fail "export-profile ${prof}: generation failed"
        continue
    fi

    # First line must be the v4+ version marker (import.cls.php requirement)
    if head -1 "$out" | grep -q '^\["_version",'; then
        log_pass "export ${prof}: v4+ _version first line"
    else
        log_fail "export ${prof}: missing _version marker"
    fi

    # Round-trip: every non-empty line parses exactly like import.cls.php does
    if command -v python3 &>/dev/null; then
        if python3 -c "
import json, sys
keys = set()
for line in open('$out'):
    line = line.strip()
    if not line: continue
    k, v = json.loads(line)
    assert isinstance(k, str) and isinstance(v, str), (k, v)
    keys.add(k)
vend = set(open('${SCRIPT_DIR}/fixtures/lscwp-option-keys-7.8.1.txt').read().split())
unknown = [k for k in keys if k != '_version' and k not in vend]
sys.exit(1 if unknown else 0)
" 2>/dev/null; then
            log_pass "export ${prof}: parses as import.cls.php would; all keys valid in 7.8.1"
        else
            log_fail "export ${prof}: round-trip/key validation failed"
        fi
    fi

    # Object-cache keys excluded by default (never disable a site's Redis blindly)
    if grep -q '"object' "$out"; then
        log_fail "export ${prof}: object-* keys present without --redis opt-in"
    else
        log_pass "export ${prof}: object-cache keys excluded by default"
    fi

    # README companion exists with import steps
    if grep -q "Toolbox > Import / Export" "${out%.data}.README.md" 2>/dev/null; then
        log_pass "export ${prof}: README companion with wp-admin steps"
    else
        log_fail "export ${prof}: README missing/incomplete"
    fi
done

# Safety invariants inside the exported woocommerce payload
woo_data="${XP_DIR}/p-woocommerce.data"
if grep -q '\["guest_optm","0"\]' "$woo_data" && grep -q '\["optm-ucss","0"\]' "$woo_data" && \
   grep -q '\["optm-css_comb","0"\]' "$woo_data" && grep -q '\["purge-stale","1"\]' "$woo_data" && \
   grep -q '\["cache-ttl_pub","604800"\]' "$woo_data"; then
    log_pass "export woocommerce: safety invariants in payload"
else
    log_fail "export woocommerce: safety invariants broken"
fi

# Redis opt-in includes object keys with lifetime 600
out_redis="${XP_DIR}/p-redis.data"
LSO_EXPORT_REDIS_HOST=127.0.0.1 "${OPTIMIZER}" export-profile --profile woocommerce --out "$out_redis" >/dev/null 2>&1 || true
if grep -q '\["object","1"\]' "$out_redis" && grep -q '\["object-life","600"\]' "$out_redis" && \
   grep -q '\["object-host","127.0.0.1"\]' "$out_redis"; then
    log_pass "export with LSO_EXPORT_REDIS_HOST: object cache wired (life 600)"
else
    log_fail "export redis opt-in wiring wrong"
fi

# Extension enforcement
out_noext="${XP_DIR}/plain-name"
"${OPTIMIZER}" export-profile --profile generic --out "$out_noext" >/dev/null 2>&1 || true
if [ -f "${out_noext}.data" ]; then
    log_pass "export-profile enforces .data extension (admin upload requirement)"
else
    log_fail "export-profile did not enforce .data extension"
fi

# Golden payload comparison
GOLDEN_XP="${GOLDEN_DIR}/export"
for prof in woocommerce wordpress generic; do
    if [ -f "${GOLDEN_XP}/p-${prof}.data" ]; then
        if diff "${GOLDEN_XP}/p-${prof}.data" "${XP_DIR}/p-${prof}.data" >/dev/null 2>&1; then
            log_pass "golden export ${prof}: payload matches"
        else
            log_fail "golden export ${prof}: payload differs"
        fi
    else
        log_fail "golden export ${prof}: golden file missing"
    fi
done

################################################################################
# SECTION 20: Runtime OPcache-Pressure Finding (analyze + mock wp eval)
################################################################################
log_section "OPcache-Pressure Tests"

# Reuse the plain-ols fixture (has a WP site); point wp at the mock with the
# "full" opcache profile -> analyze must surface the pressure findings.
OC_FIX="${TEST_TMP}/oc-fix"
OC_DATA="${TEST_TMP}/oc-data"
mkdir -p "$OC_DATA"
cp -R "${CONFIGS_DIR}/plain-ols" "$OC_FIX"
mkdir -p "$OC_FIX/etc/php.d"
oc_out=$(WP_MOCK_OPCACHE=full LSO_WP_BIN="$MOCK_WP" \
    LSO_DATA_DIR="$OC_DATA" LSO_FS_ROOT="$OC_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$OC_FIX/etc/php.d" \
    "${OPTIMIZER}" analyze 2>&1 || true)

if echo "$oc_out" | grep -qi "OPcache pool .*free.*near-full"; then
    log_pass "opcache: near-full pool flagged"
else
    log_fail "opcache: pool-full finding missing: $(echo "$oc_out" | grep -i opcache | head -3)"
fi
if echo "$oc_out" | grep -qi "hit-rate 69%"; then
    log_pass "opcache: low hit-rate (69%) flagged"
else
    log_fail "opcache: hit-rate finding missing"
fi
if echo "$oc_out" | grep -qi "interned strings buffer exhausted"; then
    log_pass "opcache: interned-strings exhaustion flagged"
else
    log_fail "opcache: interned-strings finding missing"
fi
if echo "$oc_out" | grep -qi "LSO_OPCACHE_MB="; then
    log_pass "opcache: sizing FIX hint includes LSO_OPCACHE_MB override"
else
    log_fail "opcache: sizing FIX hint missing"
fi

# Healthy profile -> pressure findings pass, not fail
oc_ok=$(WP_MOCK_OPCACHE=healthy LSO_WP_BIN="$MOCK_WP" \
    LSO_DATA_DIR="$OC_DATA" LSO_FS_ROOT="$OC_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$OC_FIX/etc/php.d" \
    "${OPTIMIZER}" analyze 2>&1 || true)
if echo "$oc_ok" | grep -qi "hit-rate 99%.*>=95" && echo "$oc_ok" | grep -qi "healthy headroom"; then
    log_pass "opcache: healthy runtime stats pass (no false alarm)"
else
    log_fail "opcache: healthy stats wrongly flagged"
fi

# The real-world CLI case: null memory stats (enable_cli=0) must NOT crash the
# audit (the pilot caught $(( )) aborting on null) — analyze must reach SCORE.
oc_null=$(WP_MOCK_OPCACHE=null LSO_WP_BIN="$MOCK_WP" \
    LSO_DATA_DIR="$OC_DATA" LSO_FS_ROOT="$OC_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$OC_FIX/etc/php.d" \
    "${OPTIMIZER}" analyze 2>&1 || true)
if echo "$oc_null" | grep -q "SCORE:"; then
    log_pass "opcache: null CLI stats don't crash analyze (reaches SCORE)"
else
    log_fail "opcache: null stats aborted analyze before SCORE"
fi
if echo "$oc_null" | grep -qi "runtime stats unreadable via CLI"; then
    log_pass "opcache: null stats reported honestly (enable_cli=0 note)"
else
    log_fail "opcache: null-stats honest note missing"
fi

# LSO_OPCACHE_MB override flows into the opcache drop-in
OV_FIX="${TEST_TMP}/ov-fix"; OV_DATA="${TEST_TMP}/ov-data"
mkdir -p "$OV_DATA"; cp -R "${CONFIGS_DIR}/plain-ols" "$OV_FIX"; mkdir -p "$OV_FIX/etc/php.d"
LSO_OPCACHE_MB=512 LSO_DATA_DIR="$OV_DATA" LSO_FS_ROOT="$OV_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$OV_FIX/etc/php.d" LSO_SKIP_RESTART=1 LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" optimize --feature opcache --force >/dev/null 2>&1 || true
if grep -q "memory_consumption=512" "$OV_FIX/etc/php.d/99-litespeed-optimizer-opcache.ini" 2>/dev/null; then
    log_pass "LSO_OPCACHE_MB override flows into opcache drop-in (512MB)"
else
    log_fail "LSO_OPCACHE_MB override not applied"
fi

################################################################################
# SECTION 21: Basic Auth (--basic-auth / LSO_HTTP_AUTH)
################################################################################
log_section "Basic Auth Tests"

if command -v python3 &>/dev/null; then
    BA_PORT=18916
    python3 - "$BA_PORT" <<'PYEOF' &
import sys, base64, http.server
USER, PW = "mltools", "mltools"
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "LiteSpeed"   # the auto Server header identifies as LiteSpeed
    sys_version = ""               # suppress Python/x.y suffix
    def _auth_ok(self):
        h = self.headers.get("Authorization", "")
        if not h.startswith("Basic "): return False
        try:
            u, p = base64.b64decode(h[6:]).decode().split(":", 1)
        except Exception:
            return False
        return u == USER and p == PW
    def do_GET(self):
        if not self._auth_ok():
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="x"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = b"<html>ok</html>"
        self.send_response(200)
        self.send_header("x-litespeed-cache", "hit")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF
    BA_PID=$!
    sleep 1

    # Without auth -> 401 -> "not LiteSpeed (or hidden)" + low score
    noauth=$(LSO_REMOTE_DELAY=0 "${OPTIMIZER}" analyze --remote "http://127.0.0.1:${BA_PORT}/" 2>&1 || true)
    # With --basic-auth -> server detected, homepage cached
    withauth=$(LSO_REMOTE_DELAY=0 "${OPTIMIZER}" analyze --remote "http://127.0.0.1:${BA_PORT}/" --basic-auth mltools:mltools 2>&1 || true)
    kill "$BA_PID" 2>/dev/null || true

    if echo "$withauth" | grep -q "served by LiteSpeed"; then
        log_pass "--basic-auth: authenticated request reaches the site"
    else
        log_fail "--basic-auth: site not reached with creds"
    fi
    if echo "$withauth" | grep -q "homepage cached"; then
        log_pass "--basic-auth: cache check works behind Basic Auth gate"
    else
        log_fail "--basic-auth: cache check failed behind gate"
    fi
    # Without creds the gate returns 401: content/cache checks can't pass (a
    # real LiteSpeed 401 still carries Server: LiteSpeed, so server detection
    # legitimately works — the difference is everything behind the gate fails).
    if ! echo "$noauth" | grep -q "homepage cached"; then
        log_pass "without --basic-auth: 401 gate blocks cache/content checks"
    else
        log_fail "without --basic-auth: cache check passed without creds"
    fi
else
    log_skip "python3 unavailable — Basic Auth tests skipped"
fi

# --basic-auth requires user:pass form
ba_bad=$("${OPTIMIZER}" analyze --remote http://127.0.0.1:1/ --basic-auth nopass 2>&1 || true)
if echo "$ba_bad" | grep -qi "requires user:password"; then
    log_pass "--basic-auth rejects malformed value"
else
    log_fail "--basic-auth accepted malformed value"
fi

################################################################################
# Summary
################################################################################
echo ""
echo "=========================================="
echo -e "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}  ${YELLOW}SKIP: $SKIP${NC}"
echo "=========================================="

[ "$FAIL" -eq 0 ]
