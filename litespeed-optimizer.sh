#!/bin/bash

################################################################################
# litespeed-optimizer - LiteSpeed / OpenLiteSpeed WordPress Optimization Tool
#
# One command to make WordPress on LiteSpeed fast and secure.
#
# Supports:
# - OpenLiteSpeed and LiteSpeed Enterprise
# - CyberPanel / cPanel / DirectAdmin / plain installs
# - Timestamped backup + verified rollback
################################################################################

set -euo pipefail

# Script version
VERSION="0.8.0"

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/litespeed-optimizer-lib"
# shellcheck disable=SC2034  # Consumed by feature modules (Phase 2+)
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
DATA_DIR="${LSO_DATA_DIR:-${HOME}/.litespeed-optimizer}"
BACKUP_DIR="${DATA_DIR}/backups"
LOG_DIR="${DATA_DIR}/logs"

# Log file with timestamp
LOG_FILE="${LOG_DIR}/litespeed-optimizer-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
# shellcheck disable=SC2034  # Used by sourced library files (ui.sh)
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Respect NO_COLOR env var (https://no-color.org/) early — before any output
if [ -n "${NO_COLOR:-}" ]; then
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" NC=""
fi

# Options
DRY_RUN=false
# shellcheck disable=SC2034  # Used by sourced library files
FORCE=false
QUIET=false
VERBOSE=false
JSON_OUTPUT=false
SHOW_VERSION=false
NO_COLOR_FLAG=false
LIST_MODE=false
REMOTE_MODE=false
OUT_FILE=""
SPECIFIC_FEATURE=""
EXCLUDE_FEATURE=""
PROFILE="auto"
TARGET_SITE=""
LOAD_MODE=false
# Space-separated allowlist of trusted IPs/CIDRs (set by --trusted-ip, or via the
# LSO_TRUSTED_IPS env var). Exempts these sources from the bad-bot blocker now,
# and from fail2ban/throttling/CAPTCHA as those live features land. Read directly
# as ${LSO_TRUSTED_IPS:-} by consumers. Honour a pre-set env value (don't clobber).
# shellcheck disable=SC2034  # consumed by lib/features/security.sh (badbots) + future live features
LSO_TRUSTED_IPS="${LSO_TRUSTED_IPS:-}"

# fail2ban opt-in gates (set by --fail2ban / --fail2ban-enable, or via env).
# Read as ${LSO_FAIL2BAN:-} / ${LSO_FAIL2BAN_ENABLE:-} by lib/features/fail2ban.sh.
# shellcheck disable=SC2034  # consumed by lib/features/fail2ban.sh
LSO_FAIL2BAN="${LSO_FAIL2BAN:-}"
# shellcheck disable=SC2034  # consumed by lib/features/fail2ban.sh
LSO_FAIL2BAN_ENABLE="${LSO_FAIL2BAN_ENABLE:-}"

# ModSecurity opt-in gate (set by --modsec, or via env). Read as ${LSO_MODSEC:-}
# by lib/features/modsec.sh. Ships DetectionOnly only; never enforces.
# shellcheck disable=SC2034  # consumed by lib/features/modsec.sh
LSO_MODSEC="${LSO_MODSEC:-}"
# ModSecurity enforce flip (--modsec-enforce). Distinct from --modsec; flips a
# DEPLOYED DetectionOnly config to SecRuleEngine On. Read as ${LSO_MODSEC_ENFORCE:-}.
# shellcheck disable=SC2034  # consumed by lib/features/modsec.sh
LSO_MODSEC_ENFORCE="${LSO_MODSEC_ENFORCE:-}"
# reCAPTCHA opt-in gate (set by --recaptcha, or via env). Read as ${LSO_RECAPTCHA:-}
# by lib/features/recaptcha.sh. Stages the OLS lsrecaptcha block DISABLED; never arms.
# shellcheck disable=SC2034  # consumed by lib/features/recaptcha.sh
LSO_RECAPTCHA="${LSO_RECAPTCHA:-}"
# reCAPTCHA arm flip (--recaptcha-enable). Distinct from --recaptcha; flips a staged
# DISABLED block to enabled 1 + writes keys. Read as ${LSO_RECAPTCHA_ENABLE:-}.
# shellcheck disable=SC2034  # consumed by lib/features/recaptcha.sh
LSO_RECAPTCHA_ENABLE="${LSO_RECAPTCHA_ENABLE:-}"
# os-limits opt-in gate (set by --os-limits, or via env). Read as ${LSO_OS_LIMITS:-}
# by lib/features/os-limits.sh. Writes OS drop-ins (systemd LimitNOFILE + sysctl);
# OS-level only (never httpd_config), default-off.
# shellcheck disable=SC2034  # consumed by lib/features/os-limits.sh
LSO_OS_LIMITS="${LSO_OS_LIMITS:-}"
# mariadb opt-in gate (set by --mariadb, or via env). Read as ${LSO_MARIADB:-}
# by lib/features/mariadb.sh. Writes a MariaDB InnoDB tuning drop-in (DB config
# only, never httpd_config), default-off.
# shellcheck disable=SC2034  # consumed by lib/features/mariadb.sh
LSO_MARIADB="${LSO_MARIADB:-}"
# http3 opt-in gate (set by --http3, or via env). Read as ${LSO_HTTP3:-} by
# lib/features/http3.sh. Flips tuning quicEnable 1 on OLS (server config); Enterprise
# / panel-managed hosts are manual-only, default-off.
# shellcheck disable=SC2034  # consumed by lib/features/http3.sh
LSO_HTTP3="${LSO_HTTP3:-}"
# redis opt-in gate (set by --redis, or via env). Read as ${LSO_REDIS:-} by
# lib/features/redis.sh. Writes an object-cache drop-in (maxmemory + allkeys-lru)
# and includes it from redis.conf; panel-managed hosts are manual-only, default-off.
# shellcheck disable=SC2034  # consumed by lib/features/redis.sh
LSO_REDIS="${LSO_REDIS:-}"
# panel-config opt-in gate (set by --panel-config/--panel, or via env). Read as
# ${LSO_PANEL_CONFIG:-} by lib/features/panel-config.sh. For panel-managed hosts
# that own/regenerate server config: writes a ready-to-apply artifact + exact
# apply steps to our data dir; never touches panel internals, default-off.
# shellcheck disable=SC2034  # consumed by lib/features/panel-config.sh
LSO_PANEL_CONFIG="${LSO_PANEL_CONFIG:-}"

# Allowed feature names / aliases for --feature and --exclude.
# These are the REGISTERED features (lib/features/*.sh); keep this list in
# sync with feature_register calls. Roadmap-only features (none) are
# intentionally NOT here — accepting them would pass validation and then fail
# at apply with "Feature not available".
ALLOWED_FEATURES=(
    "server-tuning" "tuning"
    "lsapi-tuning" "lsapi" "php-workers"
    "opcache" "php"
    "lscache" "cache"
    "lscwp" "plugin"
    "woocommerce" "woo"
    "security" "headers" "throttling"
    "fail2ban" "f2b"
    "modsec" "modsecurity" "waf"
    "recaptcha" "captcha"
    "os-limits" "oslimits"
    "mariadb" "mysql" "db"
    "http3" "quic"
    "redis" "redis-tuning"
    "panel-config" "panel"
)

ALLOWED_PROFILES=("auto" "generic" "wordpress" "woocommerce")

# Validate input name (site names, backup timestamps)
# Must be safe for use in file paths - no traversal, no special chars
_validate_input_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]] && [[ "$name" != *".."* ]] && [[ "$name" != /* ]]
}

# Validate one IPv4/IPv6 address or CIDR (these get inserted into .htaccess and
# config, so reject anything with shell/Apache metacharacters). Conservative: the
# charset alone forbids spaces, quotes, semicolons, backticks, etc.
_validate_ip() {
    local ip="$1"
    [ -n "$ip" ] || return 1
    [[ "$ip" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || return 1
    # Must contain a dot (IPv4) or a colon (IPv6) so a bare number can't pass.
    [[ "$ip" == *.* || "$ip" == *:* ]] || return 1
    # If a CIDR prefix is present, bound it (0-128 covers IPv4 /32 and IPv6 /128).
    if [[ "$ip" == */* ]]; then
        local prefix="${ip##*/}"
        [ "$prefix" -ge 0 ] && [ "$prefix" -le 128 ] || return 1
    fi
    return 0
}

# Validate feature name against allowed list
validate_feature_name() {
    local feature="$1"
    local allowed
    for allowed in "${ALLOWED_FEATURES[@]}"; do
        [[ "$feature" == "$allowed" ]] && return 0
    done
    return 1
}

validate_profile_name() {
    local profile="$1"
    local allowed
    for allowed in "${ALLOWED_PROFILES[@]}"; do
        [[ "$profile" == "$allowed" ]] && return 0
    done
    return 1
}

################################################################################
# Lock File Management
################################################################################

LOCK_FILE="${DATA_DIR}/litespeed-optimizer.lock"

acquire_lock() {
    # Portable lock using mkdir (atomic on all platforms; no flock on macOS)
    local max_attempts=3
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if mkdir "$LOCK_FILE" 2>/dev/null; then
            echo $$ > "$LOCK_FILE/pid"
            return 0
        fi

        # Lock exists - check if stale
        if [ -f "$LOCK_FILE/pid" ]; then
            local old_pid
            old_pid=$(cat "$LOCK_FILE/pid" 2>/dev/null || true)
            if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
                # Stale lock - atomically rename before cleanup to prevent race
                local stale_name="${LOCK_FILE}.stale.$$"
                if mv "$LOCK_FILE" "$stale_name" 2>/dev/null; then
                    rm -rf "$stale_name" &
                    attempt=$((attempt + 1))
                    continue
                fi
            fi
        fi

        log_error "Another instance is running (lock: $LOCK_FILE)"
        exit 1
    done

    log_error "Could not acquire lock after $max_attempts attempts"
    exit 1
}

release_lock() {
    rm -rf "$LOCK_FILE" 2>/dev/null || true
}

################################################################################
# Logging Functions
################################################################################

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info() {
    if [ "$QUIET" = false ]; then
        echo -e "${BLUE}[INFO]${NC} $*" | tee -a "${LOG_FILE}"
    else
        echo "[INFO] $*" >> "${LOG_FILE}"
    fi
}

log_success() {
    if [ "$QUIET" = false ]; then
        echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "${LOG_FILE}"
    else
        echo "[SUCCESS] $*" >> "${LOG_FILE}"
    fi
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "${LOG_FILE}"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE}"
}

# JSON output helper - pretty-prints with jq when available
json_output() {
    local data="$1"
    if command -v jq &>/dev/null; then
        echo "$data" | jq .
    else
        echo "$data"
    fi
}

################################################################################
# Initialization
################################################################################

init_directories() {
    mkdir -p "${DATA_DIR}"
    mkdir -p "${BACKUP_DIR}"
    mkdir -p "${LOG_DIR}"
}

check_prerequisites() {
    local missing=()

    for cmd in rsync curl awk; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing prerequisites: ${missing[*]}"
        echo -e "  Install: apt install ${missing[*]} (Debian/Ubuntu) or yum install ${missing[*]} (RHEL)"
        exit 1
    fi
}

source_libraries() {
    # 1. Registry (provides feature_register, feature_detect, etc.)
    if [ -f "${SCRIPT_DIR}/lib/registry.sh" ]; then
        # shellcheck source=/dev/null
        source "${SCRIPT_DIR}/lib/registry.sh"
    fi

    # 2. Core modules (helpers, sysinfo, detect-env, confedit, templates)
    local core_lib
    for core_lib in "${SCRIPT_DIR}/lib/core"/*.sh; do
        if [ -f "$core_lib" ]; then
            # shellcheck source=/dev/null
            source "$core_lib"
        fi
    done

    # 3. Feature modules (each calls feature_register) — populated in Phase 2+
    local feature_lib
    for feature_lib in "${SCRIPT_DIR}/lib/features"/*.sh; do
        if [ -f "$feature_lib" ]; then
            # shellcheck source=/dev/null
            source "$feature_lib"
        fi
    done

    # 4. Workflow libraries
    local lib
    for lib in ui detector backup validator analyzer remote-analyzer optimizer benchmark exporter probe quic-assist; do
        local lib_file="${LIB_DIR}/${lib}.sh"
        if [ -f "$lib_file" ]; then
            # shellcheck source=/dev/null
            source "$lib_file"
        fi
    done
}

################################################################################
# Help Functions
################################################################################

show_help() {
    cat << EOF
litespeed-optimizer v${VERSION} - LiteSpeed/OpenLiteSpeed WordPress Optimization Tool

One command to make WordPress on LiteSpeed fast and secure.

USAGE:
    litespeed-optimizer [COMMAND] [OPTIONS] [SITE]

COMMANDS:
    detect                      Environment report: edition, panel, paths,
                                versions, RAM/CPU tier, WP sites, services
    check                       Pre-flight readiness check (root, lswsctrl,
                                backup dir, wp-cli, panel warnings)
    analyze [site]              Scored audit 0-100 with FIX hints
    analyze --remote <url>      HTTP-only remote audit (no server access needed):
                                cache/TTFB/HTTP3/compression/security headers +
                                WooCommerce cart-safety probes. GET-only,
                                anonymous, rate-limited — run ONLY on sites
                                you own or manage
    export-profile              Generate an LSCWP settings file (.data) that
                                clients import via wp-admin > LiteSpeed Cache >
                                Toolbox > Import (no SSH needed); --profile,
                                --out <file>, --with-readme
    optimize [site]             Apply optimizations (Phase 2+); --badbots adds
                                an opt-in bad-bot .htaccess UA denylist
    rollback <timestamp>        Restore backup, restart, verify
    rollback --list             List available backups
    status [site]               Show which optimizations are applied
    benchmark <url>             Before/after TTFB + cache-hit check (Phase 4)
    benchmark --load <url>      Concurrent load test (wrk/k6/ab, else parallel
                                curl); --concurrency N, --duration N (seconds)
    probe-redis [url]           Verify the redis PHP extension in the WEB SAPI
                                (token-guarded one-shot probe dropped in docroot,
                                fetched over HTTP, self-deletes). Catches the case
                                redis-server is up but the serving lsphp lacks the
                                ext, so LSCWP object cache silently uses MySQL.
                                --basic-auth supported for gated sites.
    probe-opcache [url]         Read runtime OPcache stats from the WEB SAPI (the
                                only honest source — CLI has opcache.enable_cli=0):
                                hit-rate / pool-fill / interned / key-table, with an
                                undersized verdict. Remediation branches on whether
                                the lsphp php.ini is writable (self-fix vs contact
                                host, since opcache.* is PHP_INI_SYSTEM). Same
                                token-guarded one-shot probe. --json, --basic-auth
    quic-assist [site]          QUIC.cloud onboarding assist (read-only): preflight
                                cache/Woo correctness, BLOCK on open 'analyze' danger
                                findings, then print the exact CNAME/nameserver target
                                and STOP. Never changes DNS or config. (Account + DNS
                                are the operator's manual steps.)
    help                        Show this help message

OPTIONS:
    --dry-run                   Show what would be done without applying
    --profile <name>            auto|generic|wordpress|woocommerce (default: auto)
    --feature <name>            Apply specific feature only
    --exclude <name>            Exclude specific feature
    --force                     Skip confirmations
    -q, --quiet                 Suppress informational output (for scripting)
    --verbose                   Show detailed technical output
    --json                      Output JSON (detect, status commands)
    --basic-auth <user:pass>    Send HTTP Basic Auth on remote/benchmark/probe-redis
                                requests (for staging behind a Basic Auth gate)
    --with-readme               export-profile: also write a companion .README.md
                                with import + verification steps (default: off)
    --badbots                   security: also deploy an opt-in bad-bot UA
                                denylist to each site's .htaccess (default: off)
    --trusted-ip <ip[,ip...]>   allowlist IPs/CIDRs exempt from the bad-bot
                                blocker + fail2ban (ignoreip); comma- or
                                space-separated, repeatable
    --fail2ban                  deploy fail2ban filters + jails DISABLED
                                (wp-login/xmlrpc/4xx), opt-in (default: off)
    --fail2ban-enable           arm the jails; aborts unless the access log
                                shows the real client IP (not a CDN edge)
    --modsec                    deploy ModSecurity v3 + OWASP CRS in
                                DetectionOnly (never enforces), opt-in
    --modsec-enforce            flip a DEPLOYED DetectionOnly ModSecurity to
                                enforcing (SecRuleEngine On); gated, opt-in
    --recaptcha                 stage OLS CAPTCHA protection (lsrecaptcha)
                                DISABLED (never arms), opt-in
    --recaptcha-enable          arm a staged lsrecaptcha block (enabled 1 +
                                keys); needs LSO_RECAPTCHA_SITE_KEY /
                                LSO_RECAPTCHA_SECRET_KEY; gated, opt-in
    --os-limits                 write OS connection-limit drop-ins (systemd
                                LimitNOFILE=65535 + /etc/sysctl.d tuning),
                                opt-in (default: off)
    --mariadb                   write a MariaDB InnoDB tuning drop-in
                                (99-woocommerce.cnf; RAM-tier buffer pool),
                                opt-in (default: off)
    --http3                     enable HTTP/3 (QUIC) on OLS (tuning quicEnable 1);
                                Enterprise/panel manual-only, opt-in (default: off)
    --redis                     write a Redis object-cache tuning drop-in
                                (maxmemory per RAM + allkeys-lru; includes it from
                                redis.conf), opt-in (default: off)
    --panel-config, --panel     for panel-managed hosts (DirectAdmin/RunCloud/
                                Plesk/Enhance/ADC/…): generate a ready-to-apply
                                recommended config + the exact DESTINATION path
                                and APPLY steps for that panel; writes only to our
                                data dir, never touches panel internals, opt-in
    --no-color                  Disable colored output (also: NO_COLOR env var)
    -v, --version               Show version

FEATURES (use with --feature / --exclude):
    server-tuning               tuning{} block (maxConnections, keepalive, brotli)
    lsapi-tuning                LSAPI External App (PHP children, AVOID_FORK)
    opcache                     PHP OPcache sizing
    lscache                     server-level LSCache safety config
    lscwp                       LiteSpeed Cache plugin + curated profile import
                                (incl. Redis object-cache wiring when present)
    woocommerce                 ESI, crawler, WooCommerce cache checks
    security                    Throttling, headers, xmlrpc, CVE checks
    fail2ban                    fail2ban brute-force/scanner jails, staged
                                (opt-in via --fail2ban; NOT in default profiles)
    modsec                      ModSecurity v3 + OWASP CRS in DetectionOnly
                                (opt-in via --modsec; NOT in default profiles)
    recaptcha                   OLS CAPTCHA protection (lsrecaptcha), staged
                                disabled (opt-in via --recaptcha; NOT in profiles)
    os-limits                   OS connection limits — systemd LimitNOFILE=65535
                                + sysctl tuning (opt-in via --os-limits; NOT in
                                default profiles)
    mariadb                     MariaDB InnoDB tuning for WooCommerce/WordPress —
                                RAM-tier buffer pool (opt-in via --mariadb; NOT in
                                default profiles)
    http3                       HTTP/3 (QUIC) enablement on OLS — tuning quicEnable 1
                                (opt-in via --http3; Enterprise/panel manual-only;
                                NOT in default profiles)
    redis                       Redis object-cache tuning — maxmemory (per RAM tier)
                                + allkeys-lru drop-in (opt-in via --redis; only when
                                Redis present; NOT in default profiles)
    panel-config                Panel-specific server-config guidance — generates a
                                ready-to-apply recommended config + exact apply steps
                                for panels that own/regenerate config; never touches
                                panel internals (opt-in via --panel-config; only on
                                panel-managed hosts; NOT in default profiles)

EXAMPLES:
    # Detect environment (edition, panel, paths)
    litespeed-optimizer detect

    # Pre-flight check
    litespeed-optimizer check

    # Preview optimizations (dry-run)
    litespeed-optimizer optimize --dry-run

    # List backups / restore one
    litespeed-optimizer rollback --list
    litespeed-optimizer rollback 20260610-143022

ENVIRONMENT:
    LSO_LSWS_ROOT               Override LiteSpeed root (default: /usr/local/lsws)
    LSO_FS_ROOT                 Prefix for all absolute paths (testing/fixtures)
    LSO_DATA_DIR                Override data dir (default: ~/.litespeed-optimizer)
    LSO_RAM_MB / LSO_CORES      Override detected RAM/CPU (testing/golden tests)
    LSO_LOAD_TOOL               benchmark --load tool: wrk|k6|ab|curl (default:
                                auto-detect; auth forces curl)
    LSO_LOAD_CONCURRENCY        benchmark --load concurrency (default 10; also
                                --concurrency)
    LSO_LOAD_DURATION           benchmark --load duration in seconds (default 10;
                                also --duration)
    LSO_TRUSTED_IPS             space-separated allowlist exempt from the bad-bot
                                blocker / fail2ban / throttling (also --trusted-ip)
    Backups stored in: ${BACKUP_DIR}
    Logs stored in: ${LOG_DIR}

For more information, visit: https://github.com/MarcinDudekDev/litespeed-optimizer
EOF
}

show_version() {
    if [ "$JSON_OUTPUT" = true ]; then
        json_output "$(printf '{"version":"%s"}' "$(json_escape "${VERSION}")")"
    else
        echo "litespeed-optimizer version ${VERSION}"
    fi
}

################################################################################
# Command Functions
################################################################################

cmd_detect() {
    if ! type -t detect_environment &>/dev/null; then
        log_error "Detection library not loaded"
        exit 1
    fi

    detect_environment

    if [ "$JSON_OUTPUT" = true ]; then
        detect_report_json
    else
        detect_report
    fi
}

cmd_check() {
    local issues=0
    local warnings=0

    if type -t ui_header &>/dev/null && [ "$QUIET" = false ]; then
        ui_header
        ui_section "Pre-flight Check"
    fi

    # 1. Root check (required for live config edits, not for dry-run/fixtures)
    if [ "$(id -u)" -eq 0 ]; then
        log_success "Running as root"
    else
        log_warn "Not running as root — live optimization will require root"
        warnings=$((warnings + 1))
    fi

    # 2. Environment detection
    if type -t detect_environment &>/dev/null; then
        if detect_environment; then
            log_success "LiteSpeed found: ${LSO_EDITION} at ${LSO_LSWS_ROOT}"
            log_info "  Panel: ${LSO_PANEL}"
            log_info "  Main config: ${LSO_MAIN_CONF}"
        else
            log_error "No LiteSpeed installation found (checked /usr/local/lsws, /opt/lsws)"
            log_info "  litespeed-optimizer tunes an EXISTING install — use ols1clk to install OLS"
            issues=$((issues + 1))
        fi
    fi

    # 3. lswsctrl available
    if [ -n "${LSO_LSWS_ROOT:-}" ] && [ -x "${LSO_LSWS_ROOT}/bin/lswsctrl" ]; then
        log_success "lswsctrl found: ${LSO_LSWS_ROOT}/bin/lswsctrl"
    else
        log_warn "lswsctrl not found/executable — restart verification unavailable"
        warnings=$((warnings + 1))
    fi

    # 4. Restart command resolved
    if [ -n "${LSO_RESTART_CMD:-}" ]; then
        log_info "Restart command: ${LSO_RESTART_CMD}"
    fi

    # 5. Prerequisites
    local cmd
    for cmd in rsync curl awk; do
        if command -v "$cmd" &>/dev/null; then
            log_success "$cmd: found"
        else
            log_error "$cmd: missing"
            issues=$((issues + 1))
        fi
    done

    # 6. wp-cli (optional, needed for lscwp feature)
    if command -v wp &>/dev/null; then
        log_success "wp-cli: found"
    else
        log_warn "wp-cli: not found — LSCWP plugin features will be skipped"
        warnings=$((warnings + 1))
    fi

    # 7. Backup directory writable
    if [ -d "$BACKUP_DIR" ] && [ -w "$BACKUP_DIR" ]; then
        local backup_count
        backup_count=$(ls -1 "$BACKUP_DIR" 2>/dev/null | wc -l | tr -d ' ')
        log_success "Backup directory writable ($backup_count existing backups)"
    else
        log_error "Backup directory not writable: $BACKUP_DIR"
        issues=$((issues + 1))
    fi

    # 8. Panel-managed warnings
    case "${LSO_PANEL:-}" in
        cyberpanel)
            log_info "CyberPanel detected — full automation supported"
            ;;
        cpanel)
            log_warn "cPanel detected — server tuning applied via Apache include + .htaccess only"
            warnings=$((warnings + 1))
            ;;
        *)
            if type -t _lso_panel_restricted >/dev/null 2>&1 && _lso_panel_restricted; then
                log_warn "${LSO_PANEL} detected — server config writes are MANUAL-STEPS-ONLY"
                log_warn "  (panel regeneration/ownership clobbers direct edits; server-tuning/lsapi/lscache + security throttling become manual steps — opcache/lscwp/woocommerce + .htaccess hardening still apply)"
                warnings=$((warnings + 1))
            fi
            ;;
    esac

    # Summary
    echo ""
    if [ "$issues" -eq 0 ]; then
        log_success "Pre-flight passed ($warnings warning(s)). Safe to run optimize."
        return 0
    else
        log_error "$issues issue(s) found. Review above before optimizing."
        return 1
    fi
}

cmd_analyze() {
    if [ "$REMOTE_MODE" = true ]; then
        if [ -z "$TARGET_SITE" ]; then
            log_error "Usage: litespeed-optimizer analyze --remote <url>"
            exit 1
        fi
        if type -t run_remote_analyze &>/dev/null; then
            run_remote_analyze "$TARGET_SITE"
            return $?
        fi
        log_error "Remote analyzer library not loaded"
        exit 1
    fi

    if type -t run_analyze &>/dev/null; then
        run_analyze "$TARGET_SITE"
    else
        log_warn "Scored audit (analyze) ships in Phase 4 — not yet implemented."
        log_info "Use 'detect' for an environment report and 'status' for applied features."
        exit 1
    fi
}

cmd_quic_assist() {
    # Read-only preflight + QUIC.cloud onboarding guidance (never writes config/DNS).
    if type -t run_quic_assist &>/dev/null; then
        run_quic_assist
    else
        log_error "quic-assist library not loaded"
        exit 1
    fi
}

cmd_optimize() {
    # optimize restarts LiteSpeed and writes server config — require root unless
    # this is a dry-run or a fixture-tree test (LSO_FS_ROOT set).
    if [ "$DRY_RUN" = false ] && [ -z "${LSO_FS_ROOT:-}" ] && [ "$(id -u)" -ne 0 ]; then
        log_error "optimize must run as root (it restarts LiteSpeed and writes config). Re-run with sudo."
        exit 1
    fi

    # Snapshot the pre-change health baseline BEFORE touching anything, so the
    # post-restart health check can detect a regression. Resolve the real vhost
    # URL from the target (or first) WordPress site (catches a broken vhost the
    # default 127.0.0.1 vhost would otherwise mask). Skipped in fixture/test mode.
    if [ "$DRY_RUN" = false ] && [ "${LSO_SKIP_RESTART:-0}" != "1" ] && [ -z "${LSO_FS_ROOT:-}" ] \
        && type -t snapshot_baseline &>/dev/null; then
        # Detection populates LSO_WP_SITES — without it the vhost URL never
        # resolves and the masked-broken-vhost check silently no-ops. Idempotent:
        # create_backup/apply_optimizations re-detect only if LSO_LSWS_ROOT unset.
        if [ "${#LSO_WP_SITES[@]}" -eq 0 ] && type -t detect_environment &>/dev/null; then
            detect_environment || true
        fi
        local _vhost_site="" _vhost_url=""
        if [ -n "${TARGET_SITE:-}" ] && [ -d "${TARGET_SITE:-}" ]; then
            _vhost_site="$TARGET_SITE"
        elif [ "${#LSO_WP_SITES[@]}" -gt 0 ]; then
            _vhost_site="${LSO_WP_SITES[0]}"
        fi
        local _woo_urls="" _wc_cart="" _wc_co="" _wc_u
        if [ -n "$_vhost_site" ] && type -t lso_wp &>/dev/null; then
            _vhost_url=$(lso_wp "$_vhost_site" option get home 2>/dev/null | tr -d '\r') || _vhost_url=""
            # If the site runs WooCommerce, baseline its cart/checkout/Store-API so
            # the post-restart gate catches a checkout that a change starts 403'ing.
            # Resolve the REAL cart/checkout permalinks via WC's own helpers so a
            # custom slug (e.g. /kasse/) is gated, not a hardcoded /checkout/.
            # GET-only, anonymous, idempotent.
            if [ -n "$_vhost_url" ] && lso_wp "$_vhost_site" plugin is-active woocommerce >/dev/null 2>&1; then
                _wc_cart=$(lso_wp "$_vhost_site" eval 'echo esc_url_raw(wc_get_cart_url());' 2>/dev/null | tr -d '\r')
                _wc_co=$(lso_wp "$_vhost_site" eval 'echo esc_url_raw(wc_get_checkout_url());' 2>/dev/null | tr -d '\r')
                for _wc_u in "$_wc_cart" "$_wc_co" "${_vhost_url%/}/wp-json/wc/store/v1/products"; do
                    [ -n "$_wc_u" ] && _woo_urls="${_woo_urls:+$_woo_urls }${_wc_u}"
                done
            fi
        fi
        snapshot_baseline "$_vhost_url" "$_woo_urls"
    fi

    # Create backup first (skip on dry-run)
    if [ "$DRY_RUN" = false ]; then
        if type -t create_backup &>/dev/null; then
            create_backup "$TARGET_SITE" || { log_error "Backup failed - aborting"; exit 1; }
        else
            log_error "Backup library not loaded"
            exit 1
        fi
    fi

    if type -t apply_optimizations &>/dev/null; then
        apply_optimizations "$TARGET_SITE" "$SPECIFIC_FEATURE" "$EXCLUDE_FEATURE" "$PROFILE"
    else
        log_warn "Feature application ships in Phase 2 — no features registered yet."
        log_info "Phase 1 provides: detect, check, backup, rollback, status."
        exit 1
    fi

    # Validate and restart (verified restart-or-rollback)
    if [ "$DRY_RUN" = false ]; then
        if type -t verified_restart_or_rollback &>/dev/null; then
            verified_restart_or_rollback
        fi
    fi
}

cmd_rollback() {
    local backup_timestamp="$1"

    if [ "$LIST_MODE" = true ]; then
        if type -t list_backups &>/dev/null; then
            list_backups
            return 0
        fi
        log_error "Backup library not loaded"
        exit 1
    fi

    # Validate a supplied timestamp's format first (cheap, no privileges needed)
    # so a malformed argument is rejected the same way for any user.
    if [ -n "$backup_timestamp" ] && [[ ! "$backup_timestamp" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
        log_error "Invalid backup timestamp format: $backup_timestamp"
        log_error "Expected format: YYYYMMDD-HHMMSS (e.g., 20260610-143022)"
        exit 1
    fi

    # rollback restores config and restarts LiteSpeed — require root (before any
    # interactive prompt) unless this is a fixture-tree test (LSO_FS_ROOT set).
    if [ -z "${LSO_FS_ROOT:-}" ] && [ "$(id -u)" -ne 0 ]; then
        log_error "rollback must run as root (it restores config and restarts LiteSpeed). Re-run with sudo."
        exit 1
    fi

    if [ -z "$backup_timestamp" ]; then
        # No timestamp given. The prompt below needs a TTY — over a non-interactive
        # stdin (ssh without -t, CI, automation) `read` hits EOF and would silently
        # no-op, so fail loud instead with a clear pointer to the explicit form.
        if [ ! -t 0 ]; then
            log_error "rollback: no backup timestamp given and not running interactively."
            log_error "  List them:    litespeed-optimizer rollback --list"
            log_error "  Then restore: litespeed-optimizer rollback <YYYYMMDD-HHMMSS>"
            exit 1
        fi
        log_info "Available backups:"
        ls -1 "${BACKUP_DIR}" 2>/dev/null | tail -10 || true
        echo ""
        read -rp "Enter backup timestamp to restore: " backup_timestamp
        # Validate the prompted value (YYYYmmdd-HHMMSS) — no traversal
        if [[ ! "$backup_timestamp" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
            log_error "Invalid backup timestamp format: $backup_timestamp"
            log_error "Expected format: YYYYMMDD-HHMMSS (e.g., 20260610-143022)"
            exit 1
        fi
    fi

    if type -t restore_backup &>/dev/null; then
        restore_backup "$backup_timestamp"
    else
        log_error "Backup library not loaded"
        exit 1
    fi
}

cmd_status() {
    if ! type -t detect_environment &>/dev/null; then
        log_error "Detection library not loaded"
        exit 1
    fi
    detect_environment || true

    if [ "$JSON_OUTPUT" = true ]; then
        local features_json=""
        if type -t feature_list &>/dev/null; then
            local fid
            while IFS= read -r fid; do
                [ -z "$fid" ] && continue
                local applied="false"
                if feature_detect "$fid" "${LSO_MAIN_CONF:-/dev/null}" "$TARGET_SITE" 2>/dev/null; then
                    applied="true"
                fi
                local entry
                entry=$(printf '{"id":"%s","applied":%s}' "$(json_escape "$fid")" "$applied")
                if [ -n "$features_json" ]; then
                    features_json="${features_json},${entry}"
                else
                    features_json="$entry"
                fi
            done < <(feature_list)
        fi
        json_output "$(printf '{"command":"status","version":"%s","edition":"%s","panel":"%s","features":[%s]}' \
            "$(json_escape "$VERSION")" "$(json_escape "${LSO_EDITION:-none}")" "$(json_escape "${LSO_PANEL:-none}")" "$features_json")"
        return 0
    fi

    if type -t ui_header &>/dev/null && [ "$QUIET" = false ]; then
        ui_header
        ui_section "Optimization Status"
    fi

    if type -t show_status &>/dev/null; then
        show_status "$TARGET_SITE"
    else
        log_error "Detector library not loaded"
        exit 1
    fi
}

cmd_benchmark() {
    if [ -z "$TARGET_SITE" ]; then
        log_error "URL parameter required for benchmarks"
        log_info "Usage: litespeed-optimizer benchmark <url>"
        exit 1
    fi

    if [ "$LOAD_MODE" = true ]; then
        if type -t run_load &>/dev/null; then
            run_load "$TARGET_SITE"
        else
            log_error "Load benchmarking library not loaded"
            exit 1
        fi
        return 0
    fi

    if type -t run_benchmark &>/dev/null; then
        run_benchmark "$TARGET_SITE"
    else
        log_warn "Benchmark ships in Phase 4 — not yet implemented."
        exit 1
    fi
}

# Populate the environment globals the probes use (LSO_WP_SITES for docroot
# auto-detection, LSO_PHP_INI for the opcache self-fixable-vs-contact-host
# branch, LSO_PHP_VER for the package hint). Quiet + non-fatal: explicit
# LSO_PROBE_* overrides still win, and a box without LiteSpeed (or a fixture
# run) just leaves the globals empty rather than aborting.
_probe_detect() {
    if type -t detect_environment &>/dev/null; then
        detect_environment >/dev/null 2>&1 || true
    fi
}

cmd_probe_redis() {
    if type -t run_probe_redis &>/dev/null; then
        _probe_detect
        run_probe_redis
    else
        log_error "Probe library not loaded"
        exit 1
    fi
}

cmd_probe_opcache() {
    if type -t run_probe_opcache &>/dev/null; then
        _probe_detect
        run_probe_opcache
    else
        log_error "Probe library not loaded"
        exit 1
    fi
}

################################################################################
# Argument Parsing
################################################################################

parse_arguments() {
    COMMAND=""

    while [ $# -gt 0 ]; do
        case "$1" in
            detect|check|analyze|optimize|rollback|status|benchmark|probe-redis|probe-opcache|export-profile|quic-assist|help)
                COMMAND="$1"
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                # shellcheck disable=SC2034  # Used by sourced library files
                FORCE=true
                shift
                ;;
            -q|--quiet)
                QUIET=true
                shift
                ;;
            --verbose)
                # shellcheck disable=SC2034  # Reserved for detailed output (Phase 2+)
                VERBOSE=true
                shift
                ;;
            --json)
                JSON_OUTPUT=true
                QUIET=true  # JSON mode implies quiet
                shift
                ;;
            --remote)
                REMOTE_MODE=true
                shift
                ;;
            --out)
                if [ -z "${2:-}" ]; then log_error "--out requires a path"; exit 1; fi
                OUT_FILE="$2"
                shift 2
                ;;
            --basic-auth)
                if [ -z "${2:-}" ] || [[ "$2" != *:* ]]; then
                    log_error "--basic-auth requires user:password"
                    exit 1
                fi
                export LSO_HTTP_AUTH="$2"
                shift 2
                ;;
            --list)
                LIST_MODE=true
                shift
                ;;
            --with-readme)
                export LSO_EXPORT_README=1
                shift
                ;;
            --badbots)
                export LSO_BADBOTS=1
                shift
                ;;
            --fail2ban)
                # Opt-in: deploy fail2ban filters + jails DISABLED. Also select the
                # feature (it is not in any default profile) unless one was named.
                export LSO_FAIL2BAN=1
                [ -z "$SPECIFIC_FEATURE" ] && SPECIFIC_FEATURE="fail2ban"
                shift
                ;;
            --fail2ban-enable)
                # Arm the jails. Implies --fail2ban; the feature hard-aborts unless
                # the access log shows the real client IP (never firewall a CDN edge).
                export LSO_FAIL2BAN=1
                export LSO_FAIL2BAN_ENABLE=1
                [ -z "$SPECIFIC_FEATURE" ] && SPECIFIC_FEATURE="fail2ban"
                shift
                ;;
            --modsec)
                # Opt-in: deploy ModSecurity v3 in DetectionOnly (never enforces).
                # Also select the feature (not in any default profile) unless named.
                export LSO_MODSEC=1
                [ -z "$SPECIFIC_FEATURE" ] && SPECIFIC_FEATURE="modsec"
                shift
                ;;
            --modsec-enforce)
                # Distinct, gated flip of a DEPLOYED DetectionOnly config to enforcing.
                # Implies --modsec; refuses unless the engine is currently DetectionOnly.
                export LSO_MODSEC=1
                export LSO_MODSEC_ENFORCE=1
                [ -z "$SPECIFIC_FEATURE" ] && SPECIFIC_FEATURE="modsec"
                shift
                ;;
            --recaptcha)
                # Opt-in: stage the OLS lsrecaptcha block DISABLED (never arms).
                # Also select the feature (not in any default profile) unless named.
                export LSO_RECAPTCHA=1
                [ -z "$SPECIFIC_FEATURE" ] && SPECIFIC_FEATURE="recaptcha"
                shift
                ;;
            --recaptcha-enable)
                # Distinct, gated arm of a staged DISABLED block to enabled 1 + keys.
                # Implies --recaptcha; refuses unless staged AND both keys are in env.
                export LSO_RECAPTCHA=1
                export LSO_RECAPTCHA_ENABLE=1
                [ -z "$SPECIFIC_FEATURE" ] && SPECIFIC_FEATURE="recaptcha"
                shift
                ;;
            --os-limits|--oslimits)
                # Opt-in: write OS drop-ins (systemd LimitNOFILE=65535 + sysctl tuning).
                # OS-level only; also select the feature (not in any default profile).
                export LSO_OS_LIMITS=1
                [ -z "$SPECIFIC_FEATURE" ] && SPECIFIC_FEATURE="os-limits"
                shift
                ;;
            --mariadb|--mysql)
                # Opt-in: write the MariaDB InnoDB tuning drop-in (99-woocommerce.cnf).
                # DB config only; also select the feature (not in any default profile).
                export LSO_MARIADB=1
                [ -z "$SPECIFIC_FEATURE" ] && SPECIFIC_FEATURE="mariadb"
                shift
                ;;
            --http3|--quic)
                # Opt-in: enable HTTP/3 (QUIC) by flipping tuning quicEnable 1 on OLS.
                # Server config; also select the feature (not in any default profile).
                export LSO_HTTP3=1
                [ -z "$SPECIFIC_FEATURE" ] && SPECIFIC_FEATURE="http3"
                shift
                ;;
            --redis|--redis-tuning)
                # Opt-in: write the Redis object-cache drop-in (maxmemory + allkeys-lru)
                # and include it from redis.conf; also select the feature (not in any
                # default profile).
                export LSO_REDIS=1
                [ -z "$SPECIFIC_FEATURE" ] && SPECIFIC_FEATURE="redis"
                shift
                ;;
            --panel-config|--panel)
                # Opt-in: generate panel-specific server-config guidance + a
                # ready-to-apply artifact for panels that own/regenerate config.
                # Also select the feature (not in any default profile) unless named.
                export LSO_PANEL_CONFIG=1
                [ -z "$SPECIFIC_FEATURE" ] && SPECIFIC_FEATURE="panel-config"
                shift
                ;;
            --trusted-ip)
                if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
                    log_error "--trusted-ip requires an IP/CIDR (comma- or space-separated; repeatable)"
                    exit 1
                fi
                # Accept comma or whitespace separators; validate each; accumulate.
                _ti_raw="${2//,/ }"
                _ti_n=0
                for _ti in $_ti_raw; do
                    if ! _validate_ip "$_ti"; then
                        log_error "--trusted-ip: invalid IP/CIDR: $_ti"
                        exit 1
                    fi
                    LSO_TRUSTED_IPS="${LSO_TRUSTED_IPS:+$LSO_TRUSTED_IPS }${_ti}"
                    _ti_n=$((_ti_n + 1))
                done
                if [ "$_ti_n" -eq 0 ]; then
                    log_error "--trusted-ip: no valid IP/CIDR in '$2'"
                    exit 1
                fi
                export LSO_TRUSTED_IPS
                shift 2
                ;;
            --load)
                LOAD_MODE=true
                shift
                ;;
            --concurrency)
                if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "--concurrency requires a positive integer"
                    exit 1
                fi
                export LSO_LOAD_CONCURRENCY="$2"
                shift 2
                ;;
            --duration)
                if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "--duration requires a positive integer (seconds)"
                    exit 1
                fi
                export LSO_LOAD_DURATION="$2"
                shift 2
                ;;
            --profile)
                if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
                    log_error "--profile requires a value"
                    exit 1
                fi
                if ! validate_profile_name "$2"; then
                    log_error "Unknown profile: $2"
                    log_info "Valid profiles: ${ALLOWED_PROFILES[*]}"
                    exit 1
                fi
                PROFILE="$2"
                shift 2
                ;;
            --feature)
                if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
                    log_error "--feature requires a value"
                    exit 1
                fi
                if ! validate_feature_name "$2"; then
                    log_error "Unknown feature: $2"
                    log_info "Valid features: ${ALLOWED_FEATURES[*]}"
                    exit 1
                fi
                SPECIFIC_FEATURE="$2"
                shift 2
                ;;
            --exclude)
                if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
                    log_error "--exclude requires a value"
                    exit 1
                fi
                if ! validate_feature_name "$2"; then
                    log_error "Unknown feature to exclude: $2"
                    log_info "Valid features: ${ALLOWED_FEATURES[*]}"
                    exit 1
                fi
                EXCLUDE_FEATURE="$2"
                shift 2
                ;;
            --no-color)
                NO_COLOR_FLAG=true
                shift
                ;;
            -v|--version)
                SHOW_VERSION=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                # Site name, backup timestamp, or benchmark URL
                if [[ "$1" =~ ^https?:// ]]; then
                    TARGET_SITE="$1"
                elif [[ "$1" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
                    TARGET_SITE="$1"
                elif _validate_input_name "$1"; then
                    TARGET_SITE="$1"
                else
                    log_error "Invalid input: $1"
                    log_error "Site names can only contain: a-z, A-Z, 0-9, dots, hyphens, underscores"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Handle --version after all flags parsed (so --json works with it)
    if [ "$SHOW_VERSION" = true ]; then
        show_version
        exit 0
    fi

    if [ -z "$COMMAND" ]; then
        show_help
        exit 0
    fi
}

################################################################################
# Color Settings (applied after argument parsing)
################################################################################

apply_color_settings() {
    if [[ "$NO_COLOR_FLAG" == "true" ]] || [[ ! -t 1 ]]; then
        # shellcheck disable=SC2034  # CYAN used by sourced library files (ui.sh)
        RED="" GREEN="" YELLOW="" BLUE="" CYAN="" NC=""
    fi
}

################################################################################
# Main Function
################################################################################

main() {
    init_directories
    parse_arguments "$@"
    apply_color_settings
    acquire_lock

    # Combined cleanup handler: rollback active transactions + release lock
    cleanup_handler() {
        if type -t transaction_rollback &>/dev/null && [ "${TRANSACTION_ACTIVE:-false}" = true ]; then
            transaction_rollback
            log_warn "Transaction rolled back due to interruption" 2>/dev/null || true
        fi
        type -t _lso_auth_cleanup &>/dev/null && _lso_auth_cleanup
        release_lock
    }
    trap cleanup_handler EXIT INT TERM

    QUIET=true check_prerequisites
    source_libraries

    # Materialize the curl auth-config temp once in this (parent) shell so every
    # curl call site can read --config via $(...) without leaking a temp per request.
    type -t _lso_auth_init &>/dev/null && _lso_auth_init

    case "$COMMAND" in
        detect)    cmd_detect ;;
        export-profile)
            if type -t run_export_profile &>/dev/null; then
                run_export_profile "$PROFILE" "$OUT_FILE"
            else
                log_error "Exporter library not loaded"
                exit 1
            fi
            ;;
        check)     cmd_check ;;
        analyze)   cmd_analyze ;;
        optimize)  cmd_optimize ;;
        rollback)  cmd_rollback "$TARGET_SITE" ;;
        status)    cmd_status ;;
        benchmark) cmd_benchmark ;;
        probe-redis) cmd_probe_redis ;;
        probe-opcache) cmd_probe_opcache ;;
        quic-assist) cmd_quic_assist ;;
        help)      show_help ;;
        *)
            log_error "Unknown command: $COMMAND"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
