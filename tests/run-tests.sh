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

version_output=$("${OPTIMIZER}" --version 2>&1 || true)
if echo "$version_output" | grep -q "0.1.0"; then
    log_pass "--version returns correct version"
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
if echo "$plain_json" | grep -q '"php_ver": *"8.1"'; then
    log_pass "plain-ols: PHP version from lsphp81 dir"
else
    log_fail "plain-ols: PHP version wrong: $plain_json"
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

    if ! LSO_DATA_DIR="$data" LSO_FS_ROOT="$fix" LSO_RAM_MB="$ram" LSO_CORES="$cores" \
         LSO_PHP_INI_SCAN_DIR="$fix/etc/php.d" LSO_SKIP_RESTART=1 \
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
    LSO_PHP_INI_SCAN_DIR="$DR_FIX/etc/php.d" LSO_SKIP_RESTART=1 \
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
    LSO_PHP_INI_SCAN_DIR="$ENT_FIX/etc/php.d" LSO_SKIP_RESTART=1 \
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
    LSO_PHP_INI_SCAN_DIR="$idem_fix/etc/php.d" LSO_SKIP_RESTART=1 \
    "${OPTIMIZER}" optimize --force --quiet >/dev/null 2>&1 || true
sum2=$(file_checksum "$idem_fix/usr/local/lsws/conf/httpd_config.conf")
if [ "$sum1" = "$sum2" ]; then
    log_pass "optimize is idempotent (second run = no diff)"
else
    log_fail "optimize not idempotent"
fi

# status reports applied features after optimize
status_out=$(LSO_DATA_DIR="$IDEM_DATA" LSO_FS_ROOT="$idem_fix" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$idem_fix/etc/php.d" "${OPTIMIZER}" status 2>&1 || true)
applied_n=$(echo "$status_out" | grep -c "\[applied\]" || true)
if [ "$applied_n" -ge 4 ]; then
    log_pass "status shows 4 features applied after optimize"
else
    log_fail "status applied count wrong: $applied_n"
fi

################################################################################
# Summary
################################################################################
echo ""
echo "=========================================="
echo -e "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}  ${YELLOW}SKIP: $SKIP${NC}"
echo "=========================================="

[ "$FAIL" -eq 0 ]
