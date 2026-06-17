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
VERSION="0.5.0"

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

# Allowed feature names / aliases for --feature and --exclude.
# These are the 7 REGISTERED features (lib/features/*.sh); keep this list in
# sync with feature_register calls. Roadmap-only features (http3, redis-tuning,
# mariadb, os-limits) are intentionally NOT here — accepting them would pass
# validation and then fail at apply with "Feature not available".
ALLOWED_FEATURES=(
    "server-tuning" "tuning"
    "lsapi-tuning" "lsapi" "php-workers"
    "opcache" "php"
    "lscache" "cache"
    "lscwp" "plugin"
    "woocommerce" "woo"
    "security" "headers" "throttling"
)

ALLOWED_PROFILES=("auto" "generic" "wordpress" "woocommerce")

# Validate input name (site names, backup timestamps)
# Must be safe for use in file paths - no traversal, no special chars
_validate_input_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]] && [[ "$name" != *".."* ]] && [[ "$name" != /* ]]
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
    for lib in ui detector backup validator analyzer remote-analyzer optimizer benchmark exporter; do
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
                                --out <file>
    optimize [site]             Apply optimizations (Phase 2+)
    rollback <timestamp>        Restore backup, restart, verify
    rollback --list             List available backups
    status [site]               Show which optimizations are applied
    benchmark <url>             Before/after TTFB + cache-hit check (Phase 4)
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
    --basic-auth <user:pass>    Send HTTP Basic Auth on remote/benchmark requests
                                (for staging behind a Basic Auth gate)
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

    Planned (not yet implemented; see ROADMAP.md): http3 · redis tuning ·
    mariadb buffer pool · os-limits (systemd/sysctl)

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
    Backups stored in: ${BACKUP_DIR}
    Logs stored in: ${LOG_DIR}

For more information, visit: https://github.com/MarcinDudekDev/litespeed-optimizer
EOF
}

show_version() {
    if [ "$JSON_OUTPUT" = true ]; then
        json_output "{\"version\": \"${VERSION}\"}"
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
        directadmin|runcloud)
            log_warn "${LSO_PANEL} detected — server config writes are MANUAL-STEPS-ONLY"
            log_warn "  (panel regeneration clobbers direct edits; server-tuning/lsapi/lscache become manual steps — opcache/lscwp/woocommerce/security still apply)"
            warnings=$((warnings + 1))
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

cmd_optimize() {
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

    if [ -z "$backup_timestamp" ]; then
        log_info "Available backups:"
        ls -1 "${BACKUP_DIR}" 2>/dev/null | tail -10 || true
        echo ""
        read -rp "Enter backup timestamp to restore: " backup_timestamp
    fi

    # Validate backup timestamp format (YYYYmmdd-HHMMSS) — no traversal
    if [[ ! "$backup_timestamp" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
        log_error "Invalid backup timestamp format: $backup_timestamp"
        log_error "Expected format: YYYYMMDD-HHMMSS (e.g., 20260610-143022)"
        exit 1
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
                entry=$(printf '{"id":"%s","applied":%s}' "$fid" "$applied")
                if [ -n "$features_json" ]; then
                    features_json="${features_json},${entry}"
                else
                    features_json="$entry"
                fi
            done < <(feature_list)
        fi
        json_output "$(printf '{"command":"status","version":"%s","edition":"%s","panel":"%s","features":[%s]}' \
            "$VERSION" "${LSO_EDITION:-none}" "${LSO_PANEL:-none}" "$features_json")"
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

    if type -t run_benchmark &>/dev/null; then
        run_benchmark "$TARGET_SITE"
    else
        log_warn "Benchmark ships in Phase 4 — not yet implemented."
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
            detect|check|analyze|optimize|rollback|status|benchmark|export-profile|help)
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
        release_lock
    }
    trap cleanup_handler EXIT INT TERM

    QUIET=true check_prerequisites
    source_libraries

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
        help)      show_help ;;
        *)
            log_error "Unknown command: $COMMAND"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
