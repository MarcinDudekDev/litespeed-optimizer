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

# Panel-marker detection for the regenerate/own-config panels (Plesk, LiteSpeed
# Web ADC, Enhance, aaPanel). _detect_panel only checks directory markers, so a
# minimal LSO_FS_ROOT with just the marker dir is enough (no full LSWS tree).
# panel_marker <label> <relative-marker-dir> <expected-panel>
panel_marker() {
    local label="$1" marker="$2" want="$3"
    local got
    got=$(
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/core/detect-env.sh"
        root=$(mktemp -d "${TMPDIR:-/tmp}/lso-panel.XXXXXX")
        mkdir -p "${root}${marker}"
        export LSO_FS_ROOT="$root"
        _detect_panel
        printf '%s' "$LSO_PANEL"
        rm -rf "$root"
    )
    if [ "$got" = "$want" ]; then
        log_pass "panel detect: ${label} marker -> ${got}"
    else
        log_fail "panel detect: ${label} got '${got}', want '${want}'"
    fi
}
panel_marker "Plesk"            "/usr/local/psa"      "plesk"
panel_marker "Plesk(/opt)"      "/opt/psa"            "plesk"
panel_marker "LiteSpeed ADC"    "/usr/local/lslb"     "adc"
panel_marker "Enhance"          "/var/local/enhance"  "enhance"
panel_marker "Enhance(/opt)"    "/opt/enhance"        "enhance"
panel_marker "aaPanel"          "/www/server/panel"   "aapanel"
panel_marker "CloudPanel"       "/home/clp"           "cloudpanel"
panel_marker "Hestia"           "/usr/local/hestia"   "hestia"
panel_marker "ISPConfig"        "/usr/local/ispconfig" "ispconfig"
# No marker -> plain (regression guard for the new branches).
panel_marker "no-marker"        "/var/empty-x"        "plain"

# Each regenerate/own-config panel must be in the manual-only gate (panel_restricted).
gate_panel() {
    local panel="$1"
    local got
    got=$(
        log_info() { :; }; log_warn() { echo "WARN $*"; }; log_error() { echo "ERR $*" >&2; }
        log_success() { :; }
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/core/helpers.sh"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/core/detect-env.sh"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/litespeed-optimizer-lib/optimizer.sh"
        LSO_EDITION=ols LSO_PANEL="$panel" LSO_LSWS_ROOT=/x
        resolve_profile_features() { echo ""; }   # empty -> loop no-ops, we only want the policy log
        feature_get_by_alias() { echo ""; }
        apply_optimizations "" "" "" auto 2>&1 || true
    )
    if echo "$got" | grep -qi "manual-only"; then
        log_pass "panel gate: ${panel} -> server config manual-only"
    else
        log_fail "panel gate: ${panel} not restricted: $got"
    fi
}
for _p in directadmin runcloud plesk adc enhance aapanel cloudpanel hestia ispconfig; do
    gate_panel "$_p"
done

# security feature: OLS throttling is a SERVER-CONFIG write, so on a restricted
# panel it must be printed as manual, not written to httpd_config; on plain it is
# written. (_sec_apply_ols_throttling appends a perClientConnLimit block.)
sec_panel_throttle() {
    local panel="$1" expect="$2"  # expect = manual | written
    local tconf
    tconf=$(mktemp "${TMPDIR:-/tmp}/lso-secpanel.XXXXXX")
    printf 'tuning {\n}\n' > "$tconf"
    (
        log_info() { :; }; log_warn() { :; }; log_success() { :; }; log_error() { echo "ERR $*" >&2; }
        feature_register() { :; }   # security.sh calls it at load (registry not sourced here)
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/core/helpers.sh"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/core/detect-env.sh"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/core/confedit.sh"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/features/security.sh"
        LSO_EDITION=ols LSO_PANEL="$panel" LSO_MAIN_CONF="$tconf"
        LSO_WP_SITES=()   # no sites -> headers/badbots skip cleanly
        DRY_RUN=false
        feature_apply_custom_security >/dev/null 2>&1 || true
    ) || true
    local got=written
    grep -q "perClientConnLimit" "$tconf" || got=manual
    rm -f "$tconf"
    if [ "$got" = "$expect" ]; then
        log_pass "security throttle: ${panel} -> ${got}"
    else
        log_fail "security throttle: ${panel} got '${got}', want '${expect}'"
    fi
}
sec_panel_throttle plesk   manual
sec_panel_throttle enhance manual
sec_panel_throttle plain   written

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

# 5. LSCWP option rollback: restore_backup_files must `litespeed-option import`
#    the pre-change export back into its recorded docroot (was never done).
LSCWP_RB_DR="${TEST_TMP}/lscwp-rb-docroot"; mkdir -p "$LSCWP_RB_DR"
: > "${LSCWP_RB_DR}/wp-config.php"   # restore requires a real WP docroot
LSCWP_RB_BK="${TEST_TMP}/lscwp-rb-backup"; mkdir -p "${LSCWP_RB_BK}/lscwp"
printf '{"opt":"old"}\n' > "${LSCWP_RB_BK}/lscwp/site.json"
printf '%s\n' "$LSCWP_RB_DR" > "${LSCWP_RB_BK}/lscwp/site.docroot"
LSCWP_RB_LOG="${TEST_TMP}/lscwp-rb.log"; : > "$LSCWP_RB_LOG"
(
    set -euo pipefail
    LOG_FILE="${TEST_TMP}/lscwp-rb-run.log"; : > "$LOG_FILE"
    log_info() { :; }; log_warn() { :; }; log_success() { :; }; log_error() { :; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/backup.sh"
    lso_wp() { echo "$*" >> "$LSCWP_RB_LOG"; }   # mock: log the import call
    restore_backup_files "$LSCWP_RB_BK"
) >/dev/null 2>&1 || true
if grep -q "litespeed-option import" "$LSCWP_RB_LOG" && grep -q "site.json" "$LSCWP_RB_LOG" \
    && grep -q "$LSCWP_RB_DR" "$LSCWP_RB_LOG"; then
    log_pass "rollback restores LSCWP options (litespeed-option import into recorded docroot)"
else
    log_fail "rollback did not import LSCWP options: $(tr -d '\n' < "$LSCWP_RB_LOG")"
fi

# 6. Traversal guard: a tampered .docroot with .. must be refused (no import)
LSCWP_TR_BK="${TEST_TMP}/lscwp-tr-backup"; mkdir -p "${LSCWP_TR_BK}/lscwp"
printf '{"opt":"x"}\n' > "${LSCWP_TR_BK}/lscwp/evil.json"
printf '%s\n' "../../etc" > "${LSCWP_TR_BK}/lscwp/evil.docroot"
LSCWP_TR_LOG="${TEST_TMP}/lscwp-tr.log"; : > "$LSCWP_TR_LOG"
(
    set -euo pipefail
    LOG_FILE="${TEST_TMP}/lscwp-tr-run.log"; : > "$LOG_FILE"
    log_info() { :; }; log_warn() { :; }; log_success() { :; }; log_error() { :; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/backup.sh"
    lso_wp() { echo "$*" >> "$LSCWP_TR_LOG"; }
    restore_backup_files "$LSCWP_TR_BK"
) >/dev/null 2>&1 || true
if [ ! -s "$LSCWP_TR_LOG" ]; then
    log_pass "rollback refuses traversal docroot (.. in sidecar -> no import)"
else
    log_fail "rollback imported into unsafe docroot: $(tr -d '\n' < "$LSCWP_TR_LOG")"
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

# --- Read-your-writes: ols_get inside a live transaction sees STAGED edits, and
# the live file stays untouched until commit (the property lscache's safety guard
# relies on). ---
TXN_RYW="${TEST_TMP}/txn-ryw"
mkdir -p "$TXN_RYW"
printf 'tuning {\n  maxConnections 100\n}\n' > "$TXN_RYW/httpd.conf"
ryw=$(
    log_error() { echo "[ERROR] $*" >&2; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/confedit.sh"
    transaction_start
    ols_set "$TXN_RYW/httpd.conf" tuning maxConnections 9999
    # live file still pristine, staged value visible via ols_get
    live=$(grep -cE "maxConnections[[:space:]]+100" "$TXN_RYW/httpd.conf")
    staged=$(ols_get "$TXN_RYW/httpd.conf" tuning maxConnections)
    transaction_commit
    committed=$(ols_get "$TXN_RYW/httpd.conf" tuning maxConnections)
    echo "live=${live} staged=${staged} committed=${committed}"
)
if [ "$ryw" = "live=1 staged=9999 committed=9999" ]; then
    log_pass "txn: read-your-writes (staged value visible, live untouched until commit)"
else
    log_fail "txn read-your-writes wrong: [$ryw]"
fi

# Read-your-writes for the env-line variant (ols_set_env / ols_get_env).
TXN_RYWE="${TEST_TMP}/txn-rywe"
mkdir -p "$TXN_RYWE"
printf 'extprocessor lsphp {\n  env PHP_LSAPI_CHILDREN=10\n}\n' > "$TXN_RYWE/httpd.conf"
rywe=$(
    log_error() { echo "[ERROR] $*" >&2; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/confedit.sh"
    transaction_start
    ols_set_env "$TXN_RYWE/httpd.conf" "extprocessor lsphp" PHP_LSAPI_CHILDREN 40
    live=$(grep -cE "PHP_LSAPI_CHILDREN=10" "$TXN_RYWE/httpd.conf")
    staged=$(ols_get_env "$TXN_RYWE/httpd.conf" "extprocessor lsphp" PHP_LSAPI_CHILDREN)
    transaction_commit
    committed=$(ols_get_env "$TXN_RYWE/httpd.conf" "extprocessor lsphp" PHP_LSAPI_CHILDREN)
    echo "live=${live} staged=${staged} committed=${committed}"
)
if [ "$rywe" = "live=1 staged=40 committed=40" ]; then
    log_pass "txn: read-your-writes for ols_set_env/ols_get_env (staged env visible, live untouched)"
else
    log_fail "txn env read-your-writes wrong: [$rywe]"
fi

# --- Integration: a CONFIG-writing feature that stages an edit then FAILS rolls
# back the whole transaction — the live config is unchanged, no temps survive. ---
TXN_INT="${TEST_TMP}/txn-int"
mkdir -p "$TXN_INT"
printf 'tuning {\n  maxConnections 100\n}\n' > "$TXN_INT/httpd.conf"
(
    log_info() { :; }; log_warn() { :; }; log_success() { :; }
    log_error() { echo "[ERROR] $*" >&2; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/confedit.sh"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/optimizer.sh"
    LSO_EDITION=ols LSO_PANEL=none LSO_LSWS_ROOT=/x
    TXN_CONF="$TXN_INT/httpd.conf"
    resolve_profile_features() { echo "feat_ok feat_cfgbad"; }
    feature_get_by_alias() { echo "$1"; }
    feature_exists() { return 0; }
    feature_get() { echo "$1"; }
    feature_apply() {
        if [ "$1" = "feat_ok" ]; then ols_set "$TXN_CONF" tuning maxConnections 9999; return 0; fi
        # Stages a config edit, THEN fails mid-write -> unsafe partial config.
        ols_set "$TXN_CONF" tuning enableBr 1; return 1
    }
    apply_optimizations "" "" "" auto >/dev/null 2>&1 || true
)
if grep -qE "maxConnections[[:space:]]+100" "$TXN_INT/httpd.conf" \
   && ! grep -qE "maxConnections[[:space:]]+9999" "$TXN_INT/httpd.conf" \
   && ! grep -qE "enableBr" "$TXN_INT/httpd.conf"; then
    log_pass "txn integration: config-write failure rolls back ALL staged edits (all-or-nothing)"
else
    log_fail "txn integration: config changed despite config-write failure: $(cat "$TXN_INT/httpd.conf")"
fi
if [ "$(find "$TXN_INT" \( -name '.lso-txn.*' -o -name '.lso-confedit.*' \) | wc -l | tr -d ' ')" = "0" ]; then
    log_pass "txn integration: no temps survive a rolled-back run"
else
    log_fail "txn integration: temp files left after rollback"
fi

# --- Integration: a NON-config feature failure (wp-cli/.htaccess/.ini — stages
# no main config) must NOT discard earlier features' valid staged server config;
# that config still commits. (The H1 cross-layer-coupling fix.) ---
printf 'tuning {\n  maxConnections 100\n}\n' > "$TXN_INT/httpd.conf"
(
    log_info() { :; }; log_warn() { :; }; log_success() { :; }
    log_error() { echo "[ERROR] $*" >&2; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/confedit.sh"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/optimizer.sh"
    LSO_EDITION=ols LSO_PANEL=none LSO_LSWS_ROOT=/x
    TXN_CONF="$TXN_INT/httpd.conf"
    resolve_profile_features() { echo "feat_ok feat_nocfgbad"; }
    feature_get_by_alias() { echo "$1"; }
    feature_exists() { return 0; }
    feature_get() { echo "$1"; }
    feature_apply() {
        if [ "$1" = "feat_ok" ]; then ols_set "$TXN_CONF" tuning maxConnections 9999; return 0; fi
        return 1   # fails WITHOUT staging any config (e.g. wp-cli install error)
    }
    apply_optimizations "" "" "" auto >/dev/null 2>&1 || true
)
if grep -qE "maxConnections[[:space:]]+9999" "$TXN_INT/httpd.conf"; then
    log_pass "txn integration: non-config feature failure keeps + commits valid server config (no cross-layer rollback)"
else
    log_fail "txn integration: non-config failure wrongly discarded server config: $(cat "$TXN_INT/httpd.conf")"
fi

# --- Integration: a feature whose ols_set write FAILS but which SWALLOWS the
# error (returns 0) must NOT commit partial config — the write-error counter
# forces a rollback regardless of the feature's exit status (grok B1). ---
printf 'tuning {\n  maxConnections 100\n}\n' > "$TXN_INT/httpd.conf"
(
    log_info() { :; }; log_warn() { :; }; log_success() { :; }
    log_error() { echo "[ERROR] $*" >&2; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/confedit.sh"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/optimizer.sh"
    LSO_EDITION=ols LSO_PANEL=none LSO_LSWS_ROOT=/x
    TXN_CONF="$TXN_INT/httpd.conf"
    # Force the .lso-confedit scratch mktemp to fail (simulates disk-full mid-write);
    # the .lso-txn staging temp still succeeds. Statement-level case (not in $()).
    secure_mktemp() {
        if [ "${_LSO_FAIL_SCRATCH:-0}" = 1 ]; then
            case "$1" in *.lso-confedit.*) return 1 ;; esac
        fi
        command mktemp "$1"
    }
    resolve_profile_features() { echo "feat_ok feat_swallow"; }
    feature_get_by_alias() { echo "$1"; }
    feature_exists() { return 0; }
    feature_get() { echo "$1"; }
    feature_apply() {
        if [ "$1" = "feat_ok" ]; then ols_set "$TXN_CONF" tuning maxConnections 9999; return 0; fi
        # Real write fails, but the feature swallows it and returns success.
        _LSO_FAIL_SCRATCH=1
        ols_set "$TXN_CONF" tuning enableBr 1 || true
        _LSO_FAIL_SCRATCH=0
        return 0
    }
    apply_optimizations "" "" "" auto >/dev/null 2>&1 || true
)
if grep -qE "maxConnections[[:space:]]+100" "$TXN_INT/httpd.conf" \
   && ! grep -qE "maxConnections[[:space:]]+9999" "$TXN_INT/httpd.conf"; then
    log_pass "txn integration: swallowed config-write failure still rolls back (no partial commit)"
else
    log_fail "txn integration: partial config committed despite swallowed write failure: $(cat "$TXN_INT/httpd.conf")"
fi
if [ "$(find "$TXN_INT" \( -name '.lso-txn.*' -o -name '.lso-confedit.*' \) | wc -l | tr -d ' ')" = "0" ]; then
    log_pass "txn integration: no temps survive a swallowed-failure rollback"
else
    log_fail "txn integration: temp files left after swallowed-failure rollback"
fi

# --- Integration: success path commits ALL features' edits onto the live file
# (two features editing the SAME file -> staging dedups onto one temp), no temps. ---
printf 'tuning {\n  maxConnections 100\n}\n' > "$TXN_INT/httpd.conf"
(
    log_info() { :; }; log_warn() { :; }; log_success() { :; }
    log_error() { echo "[ERROR] $*" >&2; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/confedit.sh"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/optimizer.sh"
    LSO_EDITION=ols LSO_PANEL=none LSO_LSWS_ROOT=/x
    TXN_CONF="$TXN_INT/httpd.conf"
    resolve_profile_features() { echo "feat_one feat_two"; }
    feature_get_by_alias() { echo "$1"; }
    feature_exists() { return 0; }
    feature_get() { echo "$1"; }
    feature_apply() {
        if [ "$1" = "feat_one" ]; then ols_set "$TXN_CONF" tuning maxConnections 9999; return 0; fi
        ols_set "$TXN_CONF" tuning enableBr 1; return 0
    }
    apply_optimizations "" "" "" auto >/dev/null 2>&1 || true
)
if grep -qE "maxConnections[[:space:]]+9999" "$TXN_INT/httpd.conf" \
   && grep -qE "enableBr[[:space:]]+1" "$TXN_INT/httpd.conf"; then
    log_pass "txn integration: success commits all features' edits (same-file dedup)"
else
    log_fail "txn integration: edits missing after commit: $(cat "$TXN_INT/httpd.conf")"
fi
if [ "$(find "$TXN_INT" \( -name '.lso-txn.*' -o -name '.lso-confedit.*' \) | wc -l | tr -d ' ')" = "0" ]; then
    log_pass "txn integration: no temps survive a committed run"
else
    log_fail "txn integration: temp files left after commit"
fi

################################################################################
# SECTION 9b: json_escape helper
################################################################################
log_section "JSON Escaping Tests"

je=$(
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    json_escape 'a"b\c'
)
if [ "$je" = 'a\"b\\c' ]; then
    log_pass "json_escape: quote + backslash escaped"
else
    log_fail "json_escape quote/backslash wrong: [$je]"
fi

# A docroot containing a quote/backslash must still yield parseable JSON in
# `detect --json`. The .htaccess loop + path fields are the realistic vectors.
if command -v python3 &>/dev/null; then
    JE_FIX="${TEST_TMP}/jsonesc"
    mkdir -p "${JE_FIX}/var/www/wei\"rd\\site"
    je_json=$(
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/core/helpers.sh"
        printf '{"path":"%s"}\n' "$(json_escape 'a"b\c
d')"
    )
    if echo "$je_json" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        log_pass "json_escape: control/quote string parses as valid JSON"
    else
        log_fail "json_escape: produced invalid JSON: $je_json"
    fi
else
    log_skip "python3 unavailable — json_escape validity test skipped"
fi

################################################################################
# SECTION 9c: curl auth-config helper (creds off the curl argv)
################################################################################
log_section "curl Auth Config Tests"

# No auth configured -> init no-ops, _lso_auth_args emits nothing.
nr_empty=$(
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    unset LSO_HTTP_AUTH
    _lso_auth_init
    _lso_auth_args
)
if [ -z "$nr_empty" ]; then
    log_pass "auth: no auth -> no args emitted"
else
    log_fail "auth: expected empty, got [$nr_empty]"
fi

# Auth configured: init (parent shell) creates a mode-600 curl config with a
# quoted `user = "..."` directive; _lso_auth_args (read-only, subshell-safe)
# echoes --config <path> and re-reads the SAME path on repeated calls; the
# credential never appears in the emitted args.
NR_DIR="${TEST_TMP}/authcfg"
mkdir -p "$NR_DIR"
nr_out=$(
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    LSO_DATA_DIR="$NR_DIR"
    LSO_HTTP_AUTH="bob:s3c r3t"   # space in password: quoted form must preserve it
    _lso_auth_init
    # both reads (each in their own $(...)) must return the same path
    args=$(_lso_auth_args)
    args2=$(_lso_auth_args)
    printf '%s\n' "$args"
    [ "$args" = "$args2" ] && echo "REUSED"
)
nr_file=$(printf '%s\n' "$nr_out" | awk 'NR==1 {print $2}')
if printf '%s\n' "$nr_out" | head -1 | grep -q -- '--config ' && ! printf '%s' "$nr_out" | grep -q 's3c r3t' ; then
    log_pass "auth: emits --config, credential not on argv"
else
    log_fail "auth: args wrong or creds leaked: [$nr_out]"
fi
if printf '%s\n' "$nr_out" | grep -q "REUSED"; then
    log_pass "auth: same path returned across reads (subshell-safe)"
else
    log_fail "auth: path not stable across reads: [$nr_out]"
fi
if [ -f "$nr_file" ]; then
    nr_mode=$(stat -f '%Lp' "$nr_file" 2>/dev/null || stat -c '%a' "$nr_file" 2>/dev/null)
    if [ "$nr_mode" = "600" ] && grep -q 'user = "bob:s3c r3t"' "$nr_file"; then
        log_pass "auth: file is mode 600 with quoted user directive (whitespace-safe)"
    else
        log_fail "auth: file mode/content wrong (mode=$nr_mode)"
    fi
    rm -f "$nr_file"
else
    log_fail "auth: temp file not created at [$nr_file]"
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

################################################################################
# SECTION 12b: lsphp recycle after OPcache apply (issue #112)
################################################################################
log_section "lsphp Recycle After OPcache Apply"

# 1. Dry-run emits the would-recycle preview (reachable: opcache apply runs in
#    --dry-run preview). Reuses $dr_out from the dry-run optimize above.
if echo "$dr_out" | grep -q "\[DRY RUN\] Would gracefully recycle lsphp"; then
    log_pass "opcache recycle: --dry-run prints Would-recycle preview"
else
    log_fail "opcache recycle: Would-recycle preview missing"
fi

# 2. Real (non-dry) apply on a fixture tree (LSO_FS_ROOT set) must SKIP the
#    recycle — never signal a real process. Reuses $ent_out (real optimize run).
if echo "$ent_out" | grep -q "lsphp recycle skipped (fixture/test mode)"; then
    log_pass "opcache recycle: fixture run skips recycle"
else
    log_fail "opcache recycle: fixture-skip line missing"
fi
if echo "$ent_out" | grep -q "Recycled .* lsphp worker"; then
    log_fail "opcache recycle: fixture run actually recycled (must not)"
else
    log_pass "opcache recycle: fixture run did not recycle"
fi

# 3. Graceful recycle (unit): override the PID seam and shadow `kill` so no real
#    process is signalled. Verifies SIGTERM goes to EVERY worker first, and only
#    stragglers still alive after the grace window get SIGKILLed — a worker that
#    exits on TERM must NOT be -9'd (that hard kill mid-request is what tore the
#    Redis object-cache write and regressed the demo theme on lsdemo 2026-06-18).
#    Emulation: pid 4242 exits on SIGTERM (kill -0 -> dead); 4343 ignores it.
recycle_out=$(
    log_info() { echo "$*"; }
    log_success() { echo "$*"; }
    log_warn() { echo "$*"; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    unset LSO_FS_ROOT
    LSO_SKIP_RESTART=0
    DRY_RUN=false
    LSO_RECYCLE_GRACE=0
    _lso_lsphp_pids() { printf '%s\n' 4242 4343; }
    kill() {
        echo "KILL $*"
        if [ "$1" = "-0" ]; then
            # liveness probe: 4242 already exited on TERM, 4343 still alive
            [ "$2" = "4242" ] && return 1
            return 0
        fi
        return 0
    }
    lso_recycle_lsphp
)
# SIGTERM (bare signal) must reach BOTH workers first.
if echo "$recycle_out" | grep -qx "KILL 4242" && echo "$recycle_out" | grep -qx "KILL 4343"; then
    log_pass "lso_recycle_lsphp: SIGTERM sent to every worker first (graceful)"
else
    log_fail "lso_recycle_lsphp: graceful SIGTERM not sent to all: $recycle_out"
fi
# Only the straggler (4343) escalates to SIGKILL; the one that exited on TERM must not.
if echo "$recycle_out" | grep -q "KILL -9 4343" && ! echo "$recycle_out" | grep -q "KILL -9 4242"; then
    log_pass "lso_recycle_lsphp: SIGKILL only the straggler, not the graceful exit"
else
    log_fail "lso_recycle_lsphp: escalation wrong (must -9 only survivors): $recycle_out"
fi
if echo "$recycle_out" | grep -q "Recycled 2 lsphp worker"; then
    log_pass "lso_recycle_lsphp: reports recycled count"
else
    log_fail "lso_recycle_lsphp: recycled-count message wrong: $recycle_out"
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
        elif [ "${WP_MOCK_OPCACHE:-}" = "freehit" ]; then
            # warming/low-traffic: 79% pool free, no pressure, but hit-rate 75% (<95)
            echo '{"used":110000000,"free":402000000,"wasted":100000,"hits":750,"misses":250,"hit_rate":75,"interned_free":8388608,"keys":1300,"max_keys":50000}'
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

# Security headers deployed to the WP site .htaccess (makes `headers` alias real)
SEC_HT="$SEC_FIX/home/example.com/public_html/.htaccess"
if grep -q "# BEGIN litespeed-optimizer headers" "$SEC_HT" 2>/dev/null \
    && grep -q 'X-Content-Type-Options "nosniff"' "$SEC_HT" 2>/dev/null \
    && grep -q 'X-Frame-Options "SAMEORIGIN"' "$SEC_HT" 2>/dev/null \
    && grep -q 'Referrer-Policy' "$SEC_HT" 2>/dev/null; then
    log_pass "security: response headers deployed to site .htaccess (headers alias is truthful)"
else
    log_fail "security: headers block missing from .htaccess"
fi
# Idempotent: a second apply must not duplicate the block
sec_out2=$(LSO_DATA_DIR="$SEC_DATA" LSO_FS_ROOT="$SEC_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$SEC_FIX/etc/php.d" LSO_SKIP_RESTART=1 LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" optimize --feature security --force 2>&1 || true)
if [ "$(grep -c "# BEGIN litespeed-optimizer headers" "$SEC_HT" 2>/dev/null)" = "1" ]; then
    log_pass "security: headers block is idempotent (no duplication on re-apply)"
else
    log_fail "security: headers block duplicated on re-apply"
fi
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

# Bad-bot blocker is OPT-IN: the default security runs above (no --badbots) must
# NOT have written a badbots block.
if grep -q "# BEGIN litespeed-optimizer badbots" "$SEC_HT" 2>/dev/null; then
    log_fail "security: bad-bot block written WITHOUT --badbots (should be opt-in)"
else
    log_pass "security: bad-bot blocker is opt-in (absent by default)"
fi

# With --badbots, the per-site .htaccess gains a marker-delimited UA denylist
# with the dual authz syntax (2.4 mod_authz_core + 2.2 access_compat fallback).
sec_bb_out=$(LSO_DATA_DIR="$SEC_DATA" LSO_FS_ROOT="$SEC_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$SEC_FIX/etc/php.d" LSO_SKIP_RESTART=1 LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" optimize --feature security --badbots --force 2>&1 || true)
if grep -q "# BEGIN litespeed-optimizer badbots" "$SEC_HT" 2>/dev/null \
    && grep -q 'BrowserMatchNoCase "AhrefsBot" lso_bad_bot' "$SEC_HT" 2>/dev/null \
    && grep -q "Require not env lso_bad_bot" "$SEC_HT" 2>/dev/null \
    && grep -q "Deny from env=lso_bad_bot" "$SEC_HT" 2>/dev/null; then
    log_pass "security: --badbots deploys UA denylist with dual authz syntax"
else
    log_fail "security: --badbots block missing or malformed"
fi
# Major search engines must NOT be in the denylist (conservative list).
if grep -qiE 'BrowserMatchNoCase "(Googlebot|Bingbot|DuckDuckBot)"' "$SEC_HT" 2>/dev/null; then
    log_fail "security: bad-bot list wrongly includes a major search engine"
else
    log_pass "security: bad-bot list excludes major search engines (no false positives)"
fi
# Idempotent: a second --badbots apply must not duplicate the block.
LSO_DATA_DIR="$SEC_DATA" LSO_FS_ROOT="$SEC_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$SEC_FIX/etc/php.d" LSO_SKIP_RESTART=1 LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" optimize --feature security --badbots --force >/dev/null 2>&1 || true
if [ "$(grep -c "# BEGIN litespeed-optimizer badbots" "$SEC_HT" 2>/dev/null)" = "1" ]; then
    log_pass "security: bad-bot block is idempotent (no duplication on re-apply)"
else
    log_fail "security: bad-bot block duplicated on re-apply"
fi
# The headers block must still be present and un-duplicated alongside badbots.
if [ "$(grep -c "# BEGIN litespeed-optimizer headers" "$SEC_HT" 2>/dev/null)" = "1" ]; then
    log_pass "security: headers + badbots blocks coexist (single headers block)"
else
    log_fail "security: headers block disturbed by badbots apply"
fi

# --trusted-ip: allowlisted IPs bypass the bad-bot deny (RequireAny ip for 2.4,
# Order Deny,Allow + Allow from for 2.2). Comma list accepted.
LSO_DATA_DIR="$SEC_DATA" LSO_FS_ROOT="$SEC_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$SEC_FIX/etc/php.d" LSO_SKIP_RESTART=1 LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" optimize --feature security --badbots --trusted-ip "203.0.113.5,198.51.100.0/24" --force >/dev/null 2>&1 || true
if grep -q "Require ip 203.0.113.5 198.51.100.0/24" "$SEC_HT" 2>/dev/null \
    && grep -q "<RequireAny>" "$SEC_HT" 2>/dev/null \
    && grep -q "Allow from 203.0.113.5 198.51.100.0/24" "$SEC_HT" 2>/dev/null \
    && grep -q "Order Deny,Allow" "$SEC_HT" 2>/dev/null; then
    log_pass "security: --trusted-ip exempts allowlisted IPs from the bad-bot block (dual authz)"
else
    log_fail "security: --trusted-ip exemption missing/malformed: $(grep -A2 RequireAny "$SEC_HT" 2>/dev/null)"
fi
# Still idempotent with trusted IPs (single block).
if [ "$(grep -c "# BEGIN litespeed-optimizer badbots" "$SEC_HT" 2>/dev/null)" = "1" ]; then
    log_pass "security: badbots block idempotent with --trusted-ip"
else
    log_fail "security: badbots block duplicated with --trusted-ip"
fi
# Invalid --trusted-ip is rejected at parse time (no shell metacharacters reach .htaccess).
ti_bad_rc=0
LSO_DATA_DIR="$SEC_DATA" LSO_FS_ROOT="$SEC_FIX" \
    "${OPTIMIZER}" optimize --feature security --badbots --trusted-ip "evil; rm -rf /" --dry-run >/dev/null 2>&1 || ti_bad_rc=$?
if [ "$ti_bad_rc" -ne 0 ]; then
    log_pass "security: --trusted-ip rejects an invalid/metachar value (exit ${ti_bad_rc})"
else
    log_fail "security: --trusted-ip accepted an invalid value"
fi
# A valid IPv6 + CIDR passes validation (dry-run, no write needed).
ti_ok_rc=0
LSO_DATA_DIR="$SEC_DATA" LSO_FS_ROOT="$SEC_FIX" LSO_WP_BIN=/nonexistent LSO_SKIP_RESTART=1 \
    LSO_RAM_MB=4096 LSO_CORES=4 LSO_PHP_INI_SCAN_DIR="$SEC_FIX/etc/php.d" \
    "${OPTIMIZER}" optimize --feature security --trusted-ip "2001:db8::1 10.0.0.0/8" --dry-run >/dev/null 2>&1 || ti_ok_rc=$?
if [ "$ti_ok_rc" -eq 0 ]; then
    log_pass "security: --trusted-ip accepts IPv6 + CIDR"
else
    log_fail "security: --trusted-ip wrongly rejected a valid IPv6/CIDR (exit ${ti_ok_rc})"
fi
# An out-of-range CIDR prefix and an empty token-list are rejected.
ti_cidr_rc=0
LSO_DATA_DIR="$SEC_DATA" LSO_FS_ROOT="$SEC_FIX" \
    "${OPTIMIZER}" optimize --feature security --trusted-ip "10.0.0.0/999" --dry-run >/dev/null 2>&1 || ti_cidr_rc=$?
ti_empty_rc=0
LSO_DATA_DIR="$SEC_DATA" LSO_FS_ROOT="$SEC_FIX" \
    "${OPTIMIZER}" optimize --feature security --trusted-ip "," --dry-run >/dev/null 2>&1 || ti_empty_rc=$?
if [ "$ti_cidr_rc" -ne 0 ] && [ "$ti_empty_rc" -ne 0 ]; then
    log_pass "security: --trusted-ip rejects out-of-range CIDR and empty list"
else
    log_fail "security: --trusted-ip CIDR/empty handling wrong (cidr=${ti_cidr_rc} empty=${ti_empty_rc})"
fi
# Re-apply with --trusted-ip stays idempotent (single badbots block).
LSO_DATA_DIR="$SEC_DATA" LSO_FS_ROOT="$SEC_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$SEC_FIX/etc/php.d" LSO_SKIP_RESTART=1 LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" optimize --feature security --badbots --trusted-ip "203.0.113.5" --force >/dev/null 2>&1 || true
if [ "$(grep -c "# BEGIN litespeed-optimizer badbots" "$SEC_HT" 2>/dev/null)" = "1" ]; then
    log_pass "security: --trusted-ip re-apply is idempotent (single block)"
else
    log_fail "security: --trusted-ip re-apply duplicated the block"
fi
# Env var LSO_TRUSTED_IPS is honoured (not wiped by the global init).
LSO_DATA_DIR="$SEC_DATA" LSO_FS_ROOT="$SEC_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$SEC_FIX/etc/php.d" LSO_SKIP_RESTART=1 LSO_WP_BIN=/nonexistent \
    LSO_TRUSTED_IPS="192.0.2.7" \
    "${OPTIMIZER}" optimize --feature security --badbots --force >/dev/null 2>&1 || true
if grep -q "Require ip 192.0.2.7" "$SEC_HT" 2>/dev/null; then
    log_pass "security: LSO_TRUSTED_IPS env var honoured"
else
    log_fail "security: LSO_TRUSTED_IPS env var ignored"
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

# Bad-bot blocker audit: the default optimize above did NOT pass --badbots, so
# analyze should emit the opt-in advisory NOTE (warn, non-scoring), not a pass.
if echo "$az_after" | grep -qi "bad-bot UA blocker not deployed"; then
    log_pass "analyze: bad-bot blocker absence surfaced as advisory NOTE"
else
    log_fail "analyze: bad-bot advisory NOTE missing"
fi
# After an explicit --badbots optimize, analyze must report it deployed (pass).
LSO_DATA_DIR="$AZ_DATA" LSO_FS_ROOT="$AZ_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$AZ_FIX/etc/php.d" LSO_SKIP_RESTART=1 LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" optimize --feature security --badbots --force --quiet >/dev/null 2>&1 || true
az_bb=$(LSO_DATA_DIR="$AZ_DATA" LSO_FS_ROOT="$AZ_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$AZ_FIX/etc/php.d" LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" analyze 2>&1 || true)
if echo "$az_bb" | grep -qi "bad-bot UA blocker deployed"; then
    log_pass "analyze: deployed bad-bot blocker detected (pass)"
else
    log_fail "analyze: deployed bad-bot blocker not detected"
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
if command -v python3 &>/dev/null; then
    if echo "$az_json" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        log_pass "analyze --json is parseable JSON (escaping intact)"
    else
        log_fail "analyze --json is not valid JSON"
    fi
fi

# Web-SAPI redis-extension CLI heuristic (hybrid half): when redis-server is
# present, analyze must additionally flag whether the *vhost's* lsphp build
# carries the redis PHP extension. LSO_PHP_MODULES is the fixture seam (the
# fixture php stub is non-executable, so `php -m` cannot be run for real).
az_redis_ok=$(LSO_DATA_DIR="$AZ_DATA" LSO_FS_ROOT="$AZ_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$AZ_FIX/etc/php.d" LSO_WP_BIN=/nonexistent \
    LSO_PHP_MODULES="Core opcache redis" \
    "${OPTIMIZER}" analyze 2>&1 || true)
if echo "$az_redis_ok" | grep -q "redis PHP extension present in vhost lsphp"; then
    log_pass "analyze: redis ext present in vhost lsphp -> pass finding"
else
    log_fail "analyze: redis-ext-present finding missing"
fi

az_redis_miss=$(LSO_DATA_DIR="$AZ_DATA" LSO_FS_ROOT="$AZ_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$AZ_FIX/etc/php.d" LSO_WP_BIN=/nonexistent \
    LSO_PHP_MODULES="Core opcache" \
    "${OPTIMIZER}" analyze 2>&1 || true)
if echo "$az_redis_miss" | grep -q "redis PHP extension MISSING from vhost lsphp"; then
    log_pass "analyze: redis ext missing from vhost lsphp -> fail finding"
else
    log_fail "analyze: redis-ext-missing finding not raised"
fi
if echo "$az_redis_miss" | grep -q "probe-redis"; then
    log_pass "analyze: redis-ext-missing FIX points at probe-redis"
else
    log_fail "analyze: redis-ext-missing FIX hint missing probe-redis"
fi

# Undeterminable seam: with no LSO_PHP_MODULES the fixture php stub is not
# executable, so analyze must add NEITHER redis-ext finding (never skews score).
az_redis_unk=$(LSO_DATA_DIR="$AZ_DATA" LSO_FS_ROOT="$AZ_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$AZ_FIX/etc/php.d" LSO_WP_BIN=/nonexistent \
    "${OPTIMIZER}" analyze 2>&1 || true)
if echo "$az_redis_unk" | grep -qE "redis PHP extension (present|MISSING)"; then
    log_fail "analyze: redis-ext finding appeared when undeterminable (seam leak)"
else
    log_pass "analyze: redis-ext check silent when undeterminable (fixture php non-exec)"
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

    # Load benchmarking (--load). Force the portable curl fallback so the test is
    # deterministic regardless of whether wrk/k6/ab are installed on the box.
    load_out=$(LSO_LOAD_TOOL=curl LSO_LOAD_CONCURRENCY=4 LSO_LOAD_DURATION=2 \
        "${OPTIMIZER}" benchmark --load "http://127.0.0.1:${BENCH_PORT}/" 2>&1 || true)
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

    # --- Load test (--load, curl fallback) ---
    if echo "$load_out" | grep -q "Requests/sec"; then
        log_pass "load: reports requests/sec under concurrency"
    else
        log_fail "load: rps line missing: $(echo "$load_out" | tail -3)"
    fi
    if echo "$load_out" | grep -qi "tool=curl, concurrency=4"; then
        log_pass "load: honours LSO_LOAD_TOOL override + concurrency"
    else
        log_fail "load: tool/concurrency not honoured"
    fi
    # JSON persisted with concurrency fields, and it must be valid JSON.
    load_json=$(ls -1t "${LSO_DATA_DIR}/benchmarks"/load-*.json 2>/dev/null | head -1)
    if [ -n "$load_json" ] && \
       python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if (d["command"]=="load" and "concurrency" in d and "rps" in d and "requests" in d) else 1)' "$load_json" 2>/dev/null; then
        log_pass "load: persists valid JSON with concurrency/rps/requests fields"
    else
        log_fail "load: JSON missing or malformed"
    fi
else
    log_skip "python3 unavailable — benchmark live test skipped"
fi

# Load test degrades gracefully on an unreachable URL (no completed requests).
load_bad=$(LSO_LOAD_TOOL=curl LSO_LOAD_CONCURRENCY=2 LSO_LOAD_DURATION=1 \
    "${OPTIMIZER}" benchmark --load "http://127.0.0.1:1/" 2>&1 || true)
if echo "$load_bad" | grep -qiE "no completed requests|reachable"; then
    log_pass "load: fails gracefully when no requests complete"
else
    log_fail "load: unreachable-URL handling wrong: $(echo "$load_bad" | tail -2)"
fi

# wrk path must emit VALID JSON. wrk prints latency with a unit suffix
# ("65.83ms") and requests/sec as a float — a naive parse would write a
# non-numeric mean into the JSON. Mock a `wrk` on PATH emitting the real format
# and assert the persisted JSON parses and mean_ttfb_ms is numeric.
LOAD_WRK_BIN="${TEST_TMP}/loadbin"
mkdir -p "$LOAD_WRK_BIN"
cat > "${LOAD_WRK_BIN}/wrk" <<'WRKEOF'
#!/bin/bash
cat <<OUT
Running 2s test @ http://127.0.0.1/
  4 threads and 4 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    65.83ms   12.34ms 120.00ms   70.00%
    Req/Sec   500.00     50.00   600.00     80.00%
  4000 requests in 2.00s, 1.20MB read
Requests/sec:   2000.00
Transfer/sec:    600.00KB
OUT
WRKEOF
chmod +x "${LOAD_WRK_BIN}/wrk"
load_wrk_data="${TEST_TMP}/load-wrk-data"
mkdir -p "$load_wrk_data"
PATH="${LOAD_WRK_BIN}:${PATH}" LSO_LOAD_TOOL=wrk LSO_DATA_DIR="$load_wrk_data" \
    LSO_LOAD_CONCURRENCY=4 LSO_LOAD_DURATION=2 \
    "${OPTIMIZER}" benchmark --load "http://127.0.0.1:18999/" >/dev/null 2>&1 || true
load_wrk_json=$(ls -1t "${load_wrk_data}/benchmarks"/load-*.json 2>/dev/null | head -1)
if [ -n "$load_wrk_json" ] && command -v python3 >/dev/null 2>&1 && \
   python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d["mean_ttfb_ms"]; sys.exit(0 if (d["tool"]=="wrk" and isinstance(v,(int,float)) and d["requests"]==4000 and d["rps"]==2000) else 1)' "$load_wrk_json" 2>/dev/null; then
    log_pass "load: wrk output parsed into valid JSON (unit-stripped mean, numeric fields)"
elif ! command -v python3 >/dev/null 2>&1; then
    log_skip "load: wrk JSON test skipped (no python3)"
else
    log_fail "load: wrk JSON invalid or mis-parsed: $(cat "$load_wrk_json" 2>/dev/null)"
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
        # A well-configured ("good") site blocks known scrapers by UA -> 403.
        if MODE == "good" and "AhrefsBot" in self.headers.get("User-Agent", ""):
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
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
            if "/cart/" in path:
                body = b'<html><body><div class="wp-block-woocommerce-cart">cart</div></body></html>'
            elif "/checkout/" in path:
                body = b'<html><body><div class="wp-block-woocommerce-checkout">checkout</div></body></html>'
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
    # Bad-bot active probe: the good mock 403s the scraper UA -> detected as blocked.
    if echo "$rm_out" | grep -qi "scraper UA blocked (HTTP 403)"; then
        log_pass "remote analyze: bad-bot UA probe detects 403 block"
    else
        log_fail "remote analyze: bad-bot probe did not detect the 403"
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
    # Block-vs-shortcode guard: block-rendered cart AND checkout each warn
    if echo "$rm_out" | grep -q "cart page.*uses WooCommerce blocks"; then
        log_pass "remote: block-cart guard warns (block-disabling breaks empty-cart fallback)"
    else
        log_fail "remote: block-cart guard missing: $(echo "$rm_out" | grep -i block | head -1)"
    fi
    if echo "$rm_out" | grep -q "checkout page.*uses WooCommerce blocks"; then
        log_pass "remote: block-checkout guard warns"
    else
        log_fail "remote: block-checkout guard missing"
    fi
    # warn is advisory only — it must NOT drag the good site below the 85 gate
    if [ -n "$rm_score" ] && [ "$rm_score" -ge 85 ]; then
        log_pass "remote: block warn is non-scoring (good site still >= 85)"
    else
        log_fail "remote: block warn wrongly penalized score (${rm_score:-none})"
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

    # README companion is opt-in: default export must NOT write one.
    if [ -f "${out%.data}.README.md" ]; then
        log_fail "export ${prof}: README written without --with-readme (should be opt-in)"
    else
        log_pass "export ${prof}: no README by default (opt-in)"
    fi
done

# --with-readme opt-in produces the companion README with wp-admin steps.
out_rm="${XP_DIR}/p-readme.data"
"${OPTIMIZER}" export-profile --profile woocommerce --out "$out_rm" --with-readme >/dev/null 2>&1 || true
if grep -q "Toolbox > Import / Export" "${out_rm%.data}.README.md" 2>/dev/null; then
    log_pass "export --with-readme: README companion with wp-admin steps"
else
    log_fail "export --with-readme: README missing/incomplete"
fi

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

################################################################################
# SECTION 19b: server-tuning detect short-circuits on Enterprise (XML config)
################################################################################
log_section "Server-Tuning Enterprise Detect"

# The OLS line parser (ols_get) cannot read Enterprise XML, so running it there
# is meaningless. Stub the deps so the OLS path WOULD report "applied", then
# confirm LSO_EDITION=enterprise short-circuits to not-applied (rc 1), while the
# OLS edition still reports applied (rc 0).
st_detect_rc() {
    local edition="$1"
    (
        log_warn() { :; }; log_info() { :; }; log_error() { :; }
        sysinfo_ram_mb() { echo 4096; }
        lso_max_connections() { echo 1500; }
        ols_get() {
            case "$3" in
                maxConnections) echo 1500 ;;
                gzipAutoUpdateStatic) echo 1 ;;
            esac
        }
        feature_register() { :; }
        LSO_EDITION="$edition"
        LSO_MAIN_CONF="$ST_CONF"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/features/server-tuning.sh"
        feature_detect_custom_server_tuning "$ST_CONF"
    )
}
ST_CONF="${TEST_TMP}/st.conf"
echo "stub" > "$ST_CONF"
if st_detect_rc ols; then
    log_pass "server-tuning detect: OLS with tier values -> applied"
else
    log_fail "server-tuning detect: OLS should report applied"
fi
if st_detect_rc enterprise; then
    log_fail "server-tuning detect: Enterprise should short-circuit to not-applied"
else
    log_pass "server-tuning detect: Enterprise short-circuits (no XML line-parse)"
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

# Low hit-rate but pool MOSTLY FREE (79%) -> must NOT fail "increase memory"
# (nothing is being evicted; mirrors the probe-opcache memory-pressure gate).
oc_freehit=$(WP_MOCK_OPCACHE=freehit LSO_WP_BIN="$MOCK_WP" \
    LSO_DATA_DIR="$OC_DATA" LSO_FS_ROOT="$OC_FIX" LSO_RAM_MB=4096 LSO_CORES=4 \
    LSO_PHP_INI_SCAN_DIR="$OC_FIX/etc/php.d" \
    "${OPTIMIZER}" analyze 2>&1 || true)
if echo "$oc_freehit" | grep -qi "hit-rate 75%.*free headroom" && \
   ! echo "$oc_freehit" | grep -qi "hit-rate 75%.*recompil"; then
    log_pass "opcache: low hit-rate on a free pool not flagged as undersized (analyze)"
else
    log_fail "opcache: free-pool low-hit wrongly flagged (analyze): $(echo "$oc_freehit" | grep -i hit-rate | head -2)"
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
# SECTION 21b: probe docroot resolution on multi-vhost boxes (issue: 404)
################################################################################
log_section "Probe Docroot Resolution (multi-vhost)"

# On a box with several WP sites, a probe URL must drop its file in the docroot
# of the vhost that SERVES that URL — not just LSO_WP_SITES[0]. Otherwise the
# fetch 404s (file in docroot A, URL maps to docroot B). _probe_docroot() must
# pick the site whose WP `home` host matches the requested URL host.
probe_dr_out=$(
    log_error() { echo "[ERROR] $*" >&2; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/probe.sh"
    # Three detected sites; the requested URL belongs to the SECOND one.
    LSO_WP_SITES=("/srv/alpha" "/srv/bravo" "/srv/charlie")
    _lscwp_have_wpcli() { return 0; }
    lso_wp() {
        # $1 = docroot; emulate "wp option get home" per site.
        # (if/elif, not case: bash 3.2 mis-parses case inside $())
        if [ "$1" = "/srv/alpha" ]; then echo "https://alpha.example.com"
        elif [ "$1" = "/srv/bravo" ]; then echo "https://litespeed-demo.marcindudek.dev"
        elif [ "$1" = "/srv/charlie" ]; then echo "http://charlie.example.com"
        fi
    }
    # Requested via positional URL (TARGET_SITE), www-prefixed + trailing path to
    # exercise host normalization.
    TARGET_SITE="https://www.litespeed-demo.marcindudek.dev/wp-login.php"
    _probe_docroot
)
if [ "$probe_dr_out" = "/srv/bravo" ]; then
    log_pass "probe docroot: matches URL host to the serving vhost (/srv/bravo)"
else
    log_fail "probe docroot: picked '$probe_dr_out', expected /srv/bravo"
fi

# No URL given → fall back to the first detected site (legacy behavior).
probe_dr_fallback=$(
    log_error() { echo "[ERROR] $*" >&2; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/probe.sh"
    LSO_WP_SITES=("/srv/alpha" "/srv/bravo")
    _lscwp_have_wpcli() { return 0; }
    lso_wp() { echo ""; }
    unset TARGET_SITE LSO_PROBE_URL
    _probe_docroot
)
if [ "$probe_dr_fallback" = "/srv/alpha" ]; then
    log_pass "probe docroot: no URL -> falls back to first site"
else
    log_fail "probe docroot: fallback picked '$probe_dr_fallback', expected /srv/alpha"
fi

# Explicit LSO_PROBE_DOCROOT override always wins.
probe_dr_override=$(
    log_error() { echo "[ERROR] $*" >&2; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/probe.sh"
    LSO_WP_SITES=("/srv/alpha" "/srv/bravo")
    LSO_PROBE_DOCROOT="/srv/explicit"
    TARGET_SITE="https://litespeed-demo.marcindudek.dev"
    _probe_docroot
)
if [ "$probe_dr_override" = "/srv/explicit" ]; then
    log_pass "probe docroot: LSO_PROBE_DOCROOT override wins"
else
    log_fail "probe docroot: override picked '$probe_dr_override', expected /srv/explicit"
fi

log_section "TARGET_SITE Docroot Resolver (analyze + apply, multi-site)"

# _resolve_target_docroot() backs analyze/detect and the lscwp/woocommerce apply
# loops. The bug it replaces: a loose substring guard treated "/home/shop" as a
# match for BOTH /home/shop and /home/shop-staging. Exact-path/host match fixes it.
# Helper to run the resolver in an isolated, fully-stubbed subshell.
_run_resolver() {
    # $1 = TARGET_SITE arg; remaining env (LSO_WP_SITES, mocks) set by caller block
    (
        log_error() { echo "[ERROR] $*" >&2; }
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/core/helpers.sh"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/litespeed-optimizer-lib/probe.sh"
        LSO_WP_SITES=("/home/shop" "/home/shop-staging" "/home/blog")
        _lscwp_have_wpcli() { return 0; }
        lso_wp() {
            if [ "$1" = "/home/shop" ]; then echo "https://shop.example.com"
            elif [ "$1" = "/home/shop-staging" ]; then echo "https://staging.shop.example.com"
            elif [ "$1" = "/home/blog" ]; then echo "https://blog.example.com"
            fi
        }
        if _resolve_target_docroot "$1"; then :; else echo "__NOMATCH__"; fi
    )
}

# 1. No target -> first site (no-arg back-compat).
r=$(_run_resolver "")
if [ "$r" = "/home/shop" ]; then
    log_pass "resolver: empty target -> first site"
else
    log_fail "resolver: empty target -> '$r', expected /home/shop"
fi

# 2. Exact directory path -> that exact site (NOT the -staging sibling).
r=$(_run_resolver "/home/shop")
if [ "$r" = "/home/shop" ]; then
    log_pass "resolver: exact path /home/shop -> /home/shop (staging not substring-matched)"
else
    log_fail "resolver: exact path picked '$r', expected /home/shop"
fi

# 3. Exact path to the staging sibling -> staging (proves no cross-match either way).
r=$(_run_resolver "/home/shop-staging")
if [ "$r" = "/home/shop-staging" ]; then
    log_pass "resolver: exact path /home/shop-staging -> /home/shop-staging"
else
    log_fail "resolver: staging path picked '$r', expected /home/shop-staging"
fi

# 4. Trailing-slash directory target is normalised.
r=$(_run_resolver "/home/shop/")
if [ "$r" = "/home/shop" ]; then
    log_pass "resolver: trailing-slash path normalised -> /home/shop"
else
    log_fail "resolver: trailing-slash picked '$r', expected /home/shop"
fi

# 5. URL target -> matched by site home host (www + path stripped).
r=$(_run_resolver "https://www.staging.shop.example.com/wp-login.php")
if [ "$r" = "/home/shop-staging" ]; then
    log_pass "resolver: URL host -> serving vhost (/home/shop-staging)"
else
    log_fail "resolver: URL host picked '$r', expected /home/shop-staging"
fi

# 6. Non-empty target that matches nothing -> failure (caller falls back / skips).
r=$(_run_resolver "/home/does-not-exist")
if [ "$r" = "__NOMATCH__" ]; then
    log_pass "resolver: unknown target -> returns failure (no wrong-vhost fallback)"
else
    log_fail "resolver: unknown target returned '$r', expected failure"
fi

# 7. CLI slug form `optimize shop` -> unique basename match (/home/shop), NOT the
#    /home/shop-staging sibling (the old substring guard hit both).
r=$(_run_resolver "shop")
if [ "$r" = "/home/shop" ]; then
    log_pass "resolver: slug 'shop' -> /home/shop (unique basename, staging excluded)"
else
    log_fail "resolver: slug 'shop' picked '$r', expected /home/shop"
fi

# 8. Parent-dir containment: an absolute path that is the parent of exactly one
#    nested docroot resolves to it, trailing-slash anchored (no sibling swallow).
r=$(
    log_error() { echo "[ERROR] $*" >&2; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/probe.sh"
    LSO_WP_SITES=("/home/shop/public_html" "/home/shop-staging/public_html")
    _lscwp_have_wpcli() { return 1; }
    if _resolve_target_docroot "/home/shop"; then :; else echo "__NOMATCH__"; fi
)
if [ "$r" = "/home/shop/public_html" ]; then
    log_pass "resolver: parent path /home/shop -> nested docroot (sibling not swallowed)"
else
    log_fail "resolver: parent path picked '$r', expected /home/shop/public_html"
fi

# 9. Ambiguous basename (two sites share a basename) -> failure, not a guess.
r=$(
    log_error() { echo "[ERROR] $*" >&2; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/probe.sh"
    LSO_WP_SITES=("/home/a/shop" "/home/b/shop")
    _lscwp_have_wpcli() { return 1; }
    if _resolve_target_docroot "shop"; then :; else echo "__NOMATCH__"; fi
)
if [ "$r" = "__NOMATCH__" ]; then
    log_pass "resolver: ambiguous basename 'shop' (2 sites) -> failure (no guess)"
else
    log_fail "resolver: ambiguous basename returned '$r', expected failure"
fi

# 10. Ambiguous parent path (>=2 docroots nested under it) -> failure, not a guess.
r=$(
    log_error() { echo "[ERROR] $*" >&2; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/lib/core/helpers.sh"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/probe.sh"
    LSO_WP_SITES=("/home/shop/a" "/home/shop/b")
    _lscwp_have_wpcli() { return 1; }
    if _resolve_target_docroot "/home/shop"; then :; else echo "__NOMATCH__"; fi
)
if [ "$r" = "__NOMATCH__" ]; then
    log_pass "resolver: ambiguous parent '/home/shop' (2 nested) -> failure (no guess)"
else
    log_fail "resolver: ambiguous parent returned '$r', expected failure"
fi

################################################################################
# SECTION 22: probe-redis (web-SAPI redis-extension probe)
################################################################################
log_section "probe-redis Tests"

# Part A — faithful end-to-end with PHP's built-in server executing the REAL
# token-guarded probe. The runner's php MAY or MAY NOT carry the redis ext
# (GitHub ubuntu-latest ships it; macOS may not), so we assert the verdict is
# COHERENT with the exit code rather than a fixed outcome. Token-404, no-cache
# header, and one-shot self-delete are all environment-independent.
if command -v php &>/dev/null; then
    PR_DOCROOT="${TEST_TMP}/probe-docroot"
    mkdir -p "$PR_DOCROOT"
    PR_PORT=18917
    php -S "127.0.0.1:${PR_PORT}" -t "$PR_DOCROOT" >/dev/null 2>&1 &
    PHP_PID=$!
    sleep 1

    pr_out=$(LSO_DATA_DIR="$TEST_TMP" LSO_PROBE_DOCROOT="$PR_DOCROOT" \
        LSO_PROBE_URL="http://127.0.0.1:${PR_PORT}" \
        "${OPTIMIZER}" probe-redis 2>&1; echo "EXIT:$?")
    pr_exit=$(echo "$pr_out" | sed -n 's/^EXIT:\([0-9]*\)$/\1/p')

    # present verdict <=> exit 0 ; missing verdict <=> nonzero exit
    pr_coherent=false
    if echo "$pr_out" | grep -q "IS loaded in the web SAPI"  && [ "${pr_exit:-1}" = "0" ]; then pr_coherent=true; fi
    if echo "$pr_out" | grep -q "NOT loaded in the web SAPI" && [ "${pr_exit:-0}" != "0" ]; then pr_coherent=true; fi
    if [ "$pr_coherent" = true ]; then
        log_pass "probe-redis: real web SAPI -> verdict coherent with exit code (exit ${pr_exit})"
    else
        log_fail "probe-redis: verdict/exit incoherent: $(echo "$pr_out" | tail -3)"
    fi

    if ! ls "$PR_DOCROOT"/_lso_probe_*.php >/dev/null 2>&1; then
        log_pass "probe-redis: one-shot probe self-deleted (docroot clean)"
    else
        log_fail "probe-redis: probe file lingered in docroot"
    fi

    # Token guard + cache-bust: render the template by hand, verify the PHP itself
    # 404s a wrong token and emits LSCache no-cache headers for the right one.
    PR_TOK="deadbeefdeadbeefdeadbeefdeadbeef"
    sed -e "s/{{TOKEN}}/${PR_TOK}/g" -e "s/{{REDIS_HOST}}/127.0.0.1/g" -e "s/{{REDIS_PORT}}/6379/g" \
        templates/php/probe.php.tpl > "$PR_DOCROOT/_guard.php"
    pr_code_bad=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PR_PORT}/_guard.php?t=wrong" 2>/dev/null || echo 000)
    pr_hdrs=$(curl -s -D - -o /dev/null "http://127.0.0.1:${PR_PORT}/_guard.php?t=${PR_TOK}&cb=1" 2>/dev/null || true)
    kill "$PHP_PID" 2>/dev/null || true

    if [ "$pr_code_bad" = "404" ]; then
        log_pass "probe-redis: token guard 404s a wrong token"
    else
        log_fail "probe-redis: wrong token did not 404 (got ${pr_code_bad})"
    fi
    if echo "$pr_hdrs" | grep -qi "x-litespeed-cache-control: no-cache"; then
        log_pass "probe-redis: probe emits LSCache no-cache header (anti-stale)"
    else
        log_fail "probe-redis: no-cache header missing from probe response"
    fi
else
    log_skip "php unavailable — probe-redis live-server tests skipped"
fi

# Part B — BOTH verdicts deterministically, independent of the runner's php
# build, via a canned-JSON responder parametrized present|missing.
if command -v python3 &>/dev/null; then
    PR_SRV="${TEST_TMP}/probe_server.py"
    cat > "$PR_SRV" <<'PYEOF'
import sys, http.server
MODE = sys.argv[2]  # "present" | "missing"
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if MODE == "present":
            body = b'{"php_version":"8.3.10","sapi":"litespeed","redis_ext":"5.3.7","igbinary":true,"redis_server":"up"}'
        else:
            body = b'{"php_version":"8.3.31","sapi":"litespeed","redis_ext":false,"igbinary":false,"redis_server":null}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF
    PRJ_DOCROOT="${TEST_TMP}/probe-docroot-json"
    mkdir -p "$PRJ_DOCROOT"

    # present -> redis_ext:true, exit 0, file cleaned
    python3 "$PR_SRV" 18918 present &
    PRJ_PID=$!
    sleep 1
    prj=$(LSO_DATA_DIR="$TEST_TMP" LSO_PROBE_DOCROOT="$PRJ_DOCROOT" \
        LSO_PROBE_URL="http://127.0.0.1:18918" \
        "${OPTIMIZER}" probe-redis --json 2>/dev/null; echo "EXIT:$?")
    prj_exit=$(echo "$prj" | sed -n 's/^EXIT:\([0-9]*\)$/\1/p')
    kill "$PRJ_PID" 2>/dev/null || true

    if echo "$prj" | grep -qE '"redis_ext":[[:space:]]*true' && \
       echo "$prj" | grep -qE '"redis_server":[[:space:]]*"up"' && [ "${prj_exit:-1}" = "0" ]; then
        log_pass "probe-redis --json: present ext -> redis_ext:true, redis_server:up, exit 0"
    else
        log_fail "probe-redis --json present malformed: $(echo "$prj" | tr -d '\n')"
    fi
    if ! ls "$PRJ_DOCROOT"/_lso_probe_*.php >/dev/null 2>&1; then
        log_pass "probe-redis: probe file cleaned on success path (backstop trap)"
    else
        log_fail "probe-redis: probe lingered on success path"
    fi

    # missing -> human verdict + nonzero exit (deterministic, no real php needed)
    python3 "$PR_SRV" 18919 missing &
    PRM_PID=$!
    sleep 1
    prm=$(LSO_DATA_DIR="$TEST_TMP" LSO_PROBE_DOCROOT="$PRJ_DOCROOT" \
        LSO_PROBE_URL="http://127.0.0.1:18919" \
        "${OPTIMIZER}" probe-redis 2>&1; echo "EXIT:$?")
    prm_exit=$(echo "$prm" | sed -n 's/^EXIT:\([0-9]*\)$/\1/p')
    kill "$PRM_PID" 2>/dev/null || true

    if echo "$prm" | grep -q "NOT loaded in the web SAPI" && [ "${prm_exit:-0}" != "0" ]; then
        log_pass "probe-redis: missing ext -> MISSING verdict + nonzero exit (${prm_exit})"
    else
        log_fail "probe-redis: missing-ext verdict not raised: $(echo "$prm" | tr -d '\n')"
    fi
    # Regression: package hint strips the patch version (8.3.31 -> lsphp83-redis,
    # NOT lsphp8331). Caught live on lsdemo where PHP_VERSION is the full triple.
    if echo "$prm" | grep -q "lsphp83-redis"; then
        log_pass "probe-redis: package hint uses major.minor lsphp tag (lsphp83-redis)"
    else
        log_fail "probe-redis: package hint malformed (expected lsphp83-redis): $(echo "$prm" | tr -d '\n')"
    fi

    # Part C — probe-opcache verdict branching (agrido field thresholds), via a
    # canned-JSON responder so each trigger is exercised deterministically.
    OPC_SRV="${TEST_TMP}/opc_server.py"
    cat > "$OPC_SRV" <<'PYEOF'
import sys, http.server
BODY = sys.argv[2].encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(BODY))); self.end_headers(); self.wfile.write(BODY)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF
    OPC_DR="${TEST_TMP}/opc-docroot"; mkdir -p "$OPC_DR"
    MB=1048576
    # opcache JSON body: args = mem_used mem_free hit_rate keys scripts oom interned_free [mem_wasted]
    opc_body() {
        printf '{"php_version":"8.3.10","sapi":"litespeed","opcache":{"enabled":true,"mem_used":%d,"mem_free":%d,"mem_wasted":%d,"hit_rate":%s,"num_cached_keys":%d,"max_cached_keys":16229,"num_cached_scripts":%d,"oom_restarts":%d,"interned_used":1000,"interned_free":%d,"interned_buffer":67108864}}' \
            "$1" "$2" "${8:-1048576}" "$3" "$4" "$5" "$6" "$7"
    }
    # run probe-opcache against a canned body; sets OPC_OUT / OPC_EXIT. $1 port $2 body $3 writable
    opc_run() {
        python3 "$OPC_SRV" "$1" "$2" & local p=$!; sleep 1
        OPC_OUT=$(LSO_DATA_DIR="$TEST_TMP" LSO_PROBE_DOCROOT="$OPC_DR" \
            LSO_PROBE_URL="http://127.0.0.1:$1" LSO_OPCACHE_INI_WRITABLE="${3:-1}" \
            "${OPTIMIZER}" probe-opcache 2>&1; echo "EXIT:$?")
        kill "$p" 2>/dev/null || true
        OPC_EXIT=$(echo "$OPC_OUT" | sed -n 's/^EXIT:\([0-9]*\)$/\1/p')
    }

    opc_run 18920 "$(opc_body $((60*MB)) $((68*MB)) 99.2 1000 800 0 $((40*MB)))" 1
    if echo "$OPC_OUT" | grep -q "OPcache healthy" && [ "${OPC_EXIT:-1}" = "0" ]; then
        log_pass "probe-opcache: healthy warm cache -> healthy, exit 0"
    else
        log_fail "probe-opcache: healthy case misjudged: $(echo "$OPC_OUT" | tr -d '\n')"
    fi

    opc_run 18921 "$(opc_body $((60*MB)) $((68*MB)) 99.0 1000 800 3 $((40*MB)))" 1
    if echo "$OPC_OUT" | grep -q "oom_restarts=3" && [ "${OPC_EXIT:-0}" != "0" ]; then
        log_pass "probe-opcache: oom_restarts>0 -> undersized (definitive trigger)"
    else
        log_fail "probe-opcache: oom trigger missed: $(echo "$OPC_OUT" | tr -d '\n')"
    fi

    opc_run 18922 "$(opc_body $((120*MB)) $((5*MB)) 99.0 15500 800 0 $((40*MB)))" 1
    if echo "$OPC_OUT" | grep -qE "pool 4% free|key-table 15500" && [ "${OPC_EXIT:-0}" != "0" ]; then
        log_pass "probe-opcache: pool<10% / key-table>=95% -> undersized"
    else
        log_fail "probe-opcache: mem/key trigger missed: $(echo "$OPC_OUT" | tr -d '\n')"
    fi

    # Cold cache with a low hit-rate must NOT alarm (cumulative hit-rate, warmth gate)
    opc_run 18923 "$(opc_body $((60*MB)) $((68*MB)) 40.0 200 10 0 $((40*MB)))" 1
    if echo "$OPC_OUT" | grep -q "OPcache healthy" && echo "$OPC_OUT" | grep -qi "warming" && [ "${OPC_EXIT:-1}" = "0" ]; then
        log_pass "probe-opcache: low hit-rate on COLD cache not flagged (warmth gate)"
    else
        log_fail "probe-opcache: cold-cache warmth gate failed: $(echo "$OPC_OUT" | tr -d '\n')"
    fi

    # Warming WP (60 scripts, hit 80) must NOT flag — gate is 200, not 50 (agrido:
    # a real WP caches hundreds of scripts within the first page loads).
    opc_run 18928 "$(opc_body $((60*MB)) $((68*MB)) 80.0 1000 60 0 $((40*MB)))" 1
    if echo "$OPC_OUT" | grep -q "OPcache healthy" && [ "${OPC_EXIT:-1}" = "0" ]; then
        log_pass "probe-opcache: warming WP (60 scripts) not flagged by hit-rate (gate=200)"
    else
        log_fail "probe-opcache: warming-WP false-flagged: $(echo "$OPC_OUT" | tr -d '\n')"
    fi

    # Warm cache + low hit-rate + pool UNDER PRESSURE (15% free) -> soft trigger
    # fires (misses plausibly from eviction). free 15% is <30 (pressure) but >=10
    # (not the hard pool-full trigger), isolating the hit-rate trigger.
    opc_run 18924 "$(opc_body $((108*MB)) $((20*MB)) 80.0 1000 500 0 $((40*MB)))" 1
    if echo "$OPC_OUT" | grep -q "hit-rate 80% (<90% on a warm cache under memory pressure)" && [ "${OPC_EXIT:-0}" != "0" ]; then
        log_pass "probe-opcache: low hit-rate on WARM cache under pressure -> undersized"
    else
        log_fail "probe-opcache: warm low-hit trigger missed: $(echo "$OPC_OUT" | tr -d '\n')"
    fi

    # Warm + trustworthy-but-mediocre hit-rate (66%) but pool MOSTLY FREE (79%) and
    # no OOM -> NOT flagged: nothing is being evicted, a bigger pool can't help.
    # (This is the exact live lsdemo case that previously false-flagged "undersized
    # raise memory_consumption=2048" against a 79%-free pool.)
    opc_run 18932 "$(opc_body $((110*MB)) $((414*MB)) 66.0 1293 1259 0 $((40*MB)))" 1
    if echo "$OPC_OUT" | grep -q "OPcache healthy" && echo "$OPC_OUT" | grep -qi "bigger pool can't raise the rate" && [ "${OPC_EXIT:-1}" = "0" ]; then
        log_pass "probe-opcache: low hit-rate on a mostly-free pool not flagged (no eviction)"
    else
        log_fail "probe-opcache: free-pool low-hit false-flagged: $(echo "$OPC_OUT" | tr -d '\n')"
    fi

    # Warming AFTER a recycle: many scripts cached (>=200) but hit-rate <50% means
    # misses still dominate (one compile per script, few repeat hits yet) and the
    # pool is mostly free -> must NOT flag (this is the optimize->probe workflow).
    opc_run 18931 "$(opc_body $((70*MB)) $((442*MB)) 0.0 1259 1259 0 $((40*MB)))" 1
    if echo "$OPC_OUT" | grep -q "OPcache healthy" && echo "$OPC_OUT" | grep -qi "misses still dominate" && [ "${OPC_EXIT:-1}" = "0" ]; then
        log_pass "probe-opcache: warm-by-count but hit<50% (post-recycle) not flagged"
    else
        log_fail "probe-opcache: post-recycle warming false-flagged: $(echo "$OPC_OUT" | tr -d '\n')"
    fi

    # Key-table-only trigger names the RIGHT directive (max_accelerated_files, not memory)
    opc_run 18929 "$(opc_body $((60*MB)) $((68*MB)) 99.0 15500 800 0 $((40*MB)))" 1
    if echo "$OPC_OUT" | grep -q "opcache.max_accelerated_files=" && ! echo "$OPC_OUT" | grep -q "opcache.memory_consumption="; then
        log_pass "probe-opcache: key-table trigger -> max_accelerated_files only (trigger-specific fix)"
    else
        log_fail "probe-opcache: key-table remediation not trigger-specific: $(echo "$OPC_OUT" | tr -d '\n')"
    fi

    # Fragmentation: low free + HIGH wasted -> reset/validate_timestamps FIRST, not a blind size-up
    opc_run 18930 "$(opc_body $((90*MB)) $((5*MB)) 99.0 1000 800 0 $((40*MB)) $((38*MB)))" 1
    if echo "$OPC_OUT" | grep -qi "FRAGMENTED" && echo "$OPC_OUT" | grep -q "validate_timestamps=0" && [ "${OPC_EXIT:-0}" != "0" ]; then
        log_pass "probe-opcache: high wasted memory -> fragmentation branch (reset before sizing)"
    else
        log_fail "probe-opcache: fragmentation branch missed: $(echo "$OPC_OUT" | tr -d '\n')"
    fi

    # Host-aware remediation: not self-fixable -> contact-host, no php.ini snippet
    opc_run 18925 "$(opc_body $((120*MB)) $((5*MB)) 99.0 1000 800 0 $((40*MB)))" 0
    if echo "$OPC_OUT" | grep -qi "Contact your host" && ! echo "$OPC_OUT" | grep -q "opcache.memory_consumption="; then
        log_pass "probe-opcache: PHP_INI_SYSTEM not writable -> contact-host branch (no unappliable snippet)"
    else
        log_fail "probe-opcache: host-aware branch wrong: $(echo "$OPC_OUT" | tr -d '\n')"
    fi

    # opcache disabled in the SAPI
    python3 "$OPC_SRV" 18926 '{"php_version":"8.3.10","sapi":"litespeed","opcache":null}' & OPC_P=$!; sleep 1
    opc_dis=$(LSO_DATA_DIR="$TEST_TMP" LSO_PROBE_DOCROOT="$OPC_DR" LSO_PROBE_URL="http://127.0.0.1:18926" \
        "${OPTIMIZER}" probe-opcache 2>&1; echo "EXIT:$?")
    kill "$OPC_P" 2>/dev/null || true
    if echo "$opc_dis" | grep -q "OPcache is NOT enabled" && echo "$opc_dis" | grep -q "EXIT:1"; then
        log_pass "probe-opcache: opcache disabled in web SAPI -> flagged, exit 1"
    else
        log_fail "probe-opcache: disabled-opcache not flagged: $(echo "$opc_dis" | tr -d '\n')"
    fi

    # --json verdict shape
    python3 "$OPC_SRV" 18927 "$(opc_body $((120*MB)) $((5*MB)) 99.0 1000 800 0 $((40*MB)))" & OPC_JP=$!; sleep 1
    opc_json=$(LSO_DATA_DIR="$TEST_TMP" LSO_PROBE_DOCROOT="$OPC_DR" LSO_PROBE_URL="http://127.0.0.1:18927" \
        LSO_OPCACHE_INI_WRITABLE=1 "${OPTIMIZER}" probe-opcache --json 2>/dev/null || true)
    kill "$OPC_JP" 2>/dev/null || true
    if echo "$opc_json" | grep -qE '"verdict":[[:space:]]*"undersized"' && echo "$opc_json" | grep -qE '"opcache_enabled":[[:space:]]*true'; then
        log_pass "probe-opcache --json: verdict + opcache_enabled fields present"
    else
        log_fail "probe-opcache --json malformed: $(echo "$opc_json" | tr -d '\n')"
    fi
else
    log_skip "python3 unavailable — probe-redis/probe-opcache tests skipped"
fi

################################################################################
# SECTION 23: Safety hardening (restart RCE guard, fail-closed, root gate, vhost health)
################################################################################
log_section "Safety Hardening Tests"

# verified_restart must NOT eval the restart command: an injected metacharacter
# payload must be refused and must never execute.
SAFE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/lso-safe.XXXXXX")
inj_out=$(
    LOG_FILE="${SAFE_TMP}/log"; : > "$LOG_FILE"
    log_info() { :; }; log_warn() { :; }; log_error() { echo "ERR:$*"; }; log_success() { :; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/validator.sh"
    LSO_SKIP_RESTART=0
    unset LSO_FS_ROOT
    LSO_RESTART_CMD="true; touch ${SAFE_TMP}/pwned"
    verified_restart && echo "RC:0" || echo "RC:1"
)
if [ ! -e "${SAFE_TMP}/pwned" ] && echo "$inj_out" | grep -q "RC:1"; then
    log_pass "restart: command-injection payload refused, not executed (no eval)"
else
    log_fail "restart: injection executed or not refused: ${inj_out} pwned=$([ -e "${SAFE_TMP}/pwned" ] && echo yes || echo no)"
fi

# Empty restart command must FAIL CLOSED (return 1), not silently succeed.
empty_rc=$(
    LOG_FILE="${SAFE_TMP}/log2"; : > "$LOG_FILE"
    log_info() { :; }; log_warn() { :; }; log_error() { :; }; log_success() { :; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/validator.sh"
    LSO_SKIP_RESTART=0
    unset LSO_FS_ROOT
    LSO_RESTART_CMD=""
    verified_restart && echo "RC:0" || echo "RC:1"
)
if echo "$empty_rc" | grep -q "RC:1"; then
    log_pass "restart: empty restart command fails closed (return 1)"
else
    log_fail "restart: empty restart command did not fail closed: ${empty_rc}"
fi

# health_check must fail when the real-vhost baseline regresses even if the
# loopback URL is fine (the masked-broken-vhost case).
vhost_rc=$(
    log_info() { :; }; log_warn() { :; }; log_error() { :; }; log_success() { :; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/validator.sh"
    server_process_running() { return 0; }
    http_status() { if [ "$1" = "http://vhost/" ]; then echo 500; else echo 200; fi; }
    LSO_BASELINE_URL="http://loop/";  LSO_BASELINE_STATUS=200
    LSO_BASELINE_VHOST_URL="http://vhost/"; LSO_BASELINE_VHOST_STATUS=200
    # shrink retries so the test is fast
    sleep() { :; }
    health_check && echo "RC:0" || echo "RC:1"
)
if echo "$vhost_rc" | grep -q "RC:1"; then
    log_pass "health: broken real vhost fails the check even when loopback is OK"
else
    log_fail "health: vhost regression not caught: ${vhost_rc}"
fi

# health_check passes when both baselined URLs recover same-or-better.
vhost_ok=$(
    log_info() { :; }; log_warn() { :; }; log_error() { :; }; log_success() { :; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/validator.sh"
    server_process_running() { return 0; }
    http_status() { echo 200; }
    LSO_BASELINE_URL="http://loop/";  LSO_BASELINE_STATUS=200
    LSO_BASELINE_VHOST_URL="http://vhost/"; LSO_BASELINE_VHOST_STATUS=200
    sleep() { :; }
    health_check && echo "RC:0" || echo "RC:1"
)
if echo "$vhost_ok" | grep -q "RC:0"; then
    log_pass "health: both URLs same-or-better -> passes"
else
    log_fail "health: healthy both-URL case wrongly failed: ${vhost_ok}"
fi

# --- Woo smoke gate (Prereq A): a checkout that worked at baseline (200) but now
# 403s (ModSec/CAPTCHA) MUST fail the gate — the generic same-or-better check
# misses it because it treats 4xx as "ok". ---
woo_403=$(
    log_info() { :; }; log_warn() { :; }; log_error() { :; }; log_success() { :; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/validator.sh"
    server_process_running() { return 0; }
    sleep() { :; }
    # Baseline: everything 200. Then checkout starts 403'ing.
    http_status() { case "$1" in *"/checkout/") echo 403 ;; *) echo 200 ;; esac; }
    LSO_BASELINE_URL="http://loop/"; LSO_BASELINE_STATUS=200
    LSO_BASELINE_VHOST_URL="http://shop/"; LSO_BASELINE_VHOST_STATUS=200
    LSO_BASELINE_WOO_URLS=("http://shop/cart/" "http://shop/checkout/" "http://shop/wp-json/wc/store/v1/products")
    LSO_BASELINE_WOO_STATUS=(200 200 200)
    health_check && echo "RC:0" || echo "RC:1"
)
if echo "$woo_403" | grep -q "RC:1"; then
    log_pass "woo gate: new 403 on checkout fails the health gate (homepage-200 blind spot closed)"
else
    log_fail "woo gate: checkout 403 not caught: ${woo_403}"
fi
# Contrast: the OLD generic check PASSES that same 403 (4xx = "ok"); the Woo
# check fails it. Stub http_status to 403 to isolate the 4xx contrast.
woo_contrast=$(
    log_info() { :; }; log_warn() { :; }; log_success() { :; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/validator.sh"
    http_status() { echo 403; }
    _health_url_ok "http://shop/checkout/" 200 && echo "GENERIC:pass" || echo "GENERIC:fail"
    _health_woo_url_ok "http://shop/checkout/" 200 && echo "WOO:pass" || echo "WOO:fail"
)
if echo "$woo_contrast" | grep -q "GENERIC:pass" && echo "$woo_contrast" | grep -q "WOO:fail"; then
    log_pass "woo gate: stricter than generic check (generic passes 403, woo fails it)"
else
    log_fail "woo gate: strictness contrast wrong: ${woo_contrast}"
fi
# Healthy Woo flows pass.
woo_ok=$(
    log_info() { :; }; log_warn() { :; }; log_error() { :; }; log_success() { :; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/validator.sh"
    server_process_running() { return 0; }; sleep() { :; }
    http_status() { echo 200; }
    LSO_BASELINE_URL="http://loop/"; LSO_BASELINE_STATUS=200
    LSO_BASELINE_WOO_URLS=("http://shop/cart/" "http://shop/checkout/")
    LSO_BASELINE_WOO_STATUS=(200 200)
    health_check && echo "RC:0" || echo "RC:1"
)
if echo "$woo_ok" | grep -q "RC:0"; then
    log_pass "woo gate: all Woo flows still 2xx -> passes"
else
    log_fail "woo gate: healthy Woo case wrongly failed: ${woo_ok}"
fi
# A flow already broken at baseline (403) is NOT attributed to us (no false fail).
woo_pre=$(
    log_info() { :; }; log_warn() { :; }; log_error() { :; }; log_success() { :; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/validator.sh"
    server_process_running() { return 0; }; sleep() { :; }
    http_status() { echo 403; }   # checkout still 403 after, but it was 403 before too
    LSO_BASELINE_URL="http://loop/"; LSO_BASELINE_STATUS=200
    LSO_BASELINE_WOO_URLS=("http://shop/checkout/"); LSO_BASELINE_WOO_STATUS=(403)
    health_check && echo "RC:0" || echo "RC:1"
)
if echo "$woo_pre" | grep -q "RC:0"; then
    log_pass "woo gate: pre-existing checkout 403 not attributed to the run (no false fail)"
else
    log_fail "woo gate: pre-broken checkout wrongly failed the gate: ${woo_pre}"
fi
# snapshot_baseline populates the Woo arrays only when a woo base URL is given.
woo_snap=$(
    log_info() { :; }; log_warn() { :; }; log_success() { :; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/validator.sh"
    http_status() { echo 200; }
    snapshot_baseline "http://shop/" "http://shop/"
    echo "n=${#LSO_BASELINE_WOO_URLS[@]} first=${LSO_BASELINE_WOO_URLS[0]:-}"
)
if echo "$woo_snap" | grep -q "n=3 first=http://shop/cart/"; then
    log_pass "woo gate: snapshot_baseline records cart/checkout/Store-API when site is Woo"
else
    log_fail "woo gate: snapshot Woo baseline wrong: ${woo_snap}"
fi
woo_nosnap=$(
    log_info() { :; }; log_warn() { :; }; log_success() { :; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/validator.sh"
    http_status() { echo 200; }
    snapshot_baseline "http://shop/"
    echo "n=${#LSO_BASELINE_WOO_URLS[@]}"
)
if echo "$woo_nosnap" | grep -q "n=0"; then
    log_pass "woo gate: non-Woo run baselines no Woo flows (gate is a no-op)"
else
    log_fail "woo gate: Woo baseline set without a woo base URL: ${woo_nosnap}"
fi

# health_check: a URL whose baseline was unreachable (000) contributes no HTTP
# signal — process-up alone passes (no false-fail when baseline was already down).
base000=$(
    log_info() { :; }; log_warn() { :; }; log_error() { :; }; log_success() { :; }
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/litespeed-optimizer-lib/validator.sh"
    server_process_running() { return 0; }
    http_status() { echo 503; }   # would FAIL if it were treated as a signal
    LSO_BASELINE_URL="http://loop/";  LSO_BASELINE_STATUS=000
    LSO_BASELINE_VHOST_URL=""; LSO_BASELINE_VHOST_STATUS=""
    sleep() { :; }
    health_check && echo "RC:0" || echo "RC:1"
)
if echo "$base000" | grep -q "RC:0"; then
    log_pass "health: 000 baseline contributes no signal (process-up passes)"
else
    log_fail "health: 000-baseline no-signal case wrongly failed: ${base000}"
fi

# Root gate: optimize/rollback (no fixture, non-root) must demand root. Skip when
# the suite itself runs as root (gate is correctly bypassed then).
if [ "$(id -u)" -ne 0 ]; then
    gate_opt=$(LSO_DATA_DIR="$SAFE_TMP" "${OPTIMIZER}" optimize --profile generic 2>&1 || true)
    if echo "$gate_opt" | grep -qi "must run as root"; then
        log_pass "root gate: optimize refuses to run as non-root (no fixture)"
    else
        log_fail "root gate: optimize did not require root: $(echo "$gate_opt" | head -1)"
    fi
    gate_rb=$(LSO_DATA_DIR="$SAFE_TMP" "${OPTIMIZER}" rollback 20260101-000000 2>&1 || true)
    if echo "$gate_rb" | grep -qi "must run as root"; then
        log_pass "root gate: rollback refuses to run as non-root (no fixture)"
    else
        log_fail "root gate: rollback did not require root: $(echo "$gate_rb" | head -1)"
    fi
else
    log_skip "root gate test skipped (suite running as root)"
fi
rm -rf "$SAFE_TMP"

################################################################################
# Summary
################################################################################
echo ""
echo "=========================================="
echo -e "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}  ${YELLOW}SKIP: $SKIP${NC}"
echo "=========================================="

[ "$FAIL" -eq 0 ]
