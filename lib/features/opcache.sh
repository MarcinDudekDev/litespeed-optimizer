#!/bin/bash
# shellcheck disable=SC2034  # FEATURE_* vars are consumed by lib/registry.sh feature_register
################################################################################
# features/opcache.sh - PHP OPcache Sizing (SPEC §6 opcache)
################################################################################
# Deploys a drop-in ini (99-litespeed-optimizer-opcache.ini) into the php.ini
# scan directory, then triggers $LSO_PHP_RESTART. Same path for OLS and LSWS.
#
# Scan dir resolution (never hardcode — DirectAdmin uses /usr/local/phpXX):
#   1. LSO_PHP_INI_SCAN_DIR env override (tests / unusual layouts)
#   2. <dirname of resolved php.ini>/conf.d if it exists
#   3. otherwise report-only with manual instructions
################################################################################

OPCACHE_INI_NAME="99-litespeed-optimizer-opcache.ini"

_opcache_max_files() {
    case "$1" in
        1g|2g) echo 20000 ;;
        4g)    echo 30000 ;;
        *)     echo 50000 ;;
    esac
}

_opcache_interned() {
    case "$1" in
        1g|2g) echo 16 ;;
        *)     echo 32 ;;
    esac
}

# Resolve the additional-.ini scan dir; prints path or returns 1.
# Order: explicit override > ask the PHP binary (authoritative) > conf.d guess.
# Never assume conf.d/ — OLS lsphp uses .../etc/php/<v>/mods-available/, cPanel
# ea-php uses .../php.d/, DirectAdmin /usr/local/phpXX/lib/php.conf.d, etc.
_opcache_scan_dir() {
    if [ -n "${LSO_PHP_INI_SCAN_DIR:-}" ]; then
        echo "$LSO_PHP_INI_SCAN_DIR"
        return 0
    fi
    # Ask the actual binary where it scans for additional .ini files (skip on
    # fixture trees where the binary isn't runnable).
    if [ -n "${LSO_PHP_BIN:-}" ] && [ -x "$LSO_PHP_BIN" ] && [ -z "${LSO_FS_ROOT:-}" ]; then
        local scan
        scan=$("$LSO_PHP_BIN" --ini 2>/dev/null | sed -n 's/^Scan for additional \.ini files in:[[:space:]]*//p' | head -1)
        # php prints "(none)" when no scan dir is configured
        if [ -n "$scan" ] && [ "$scan" != "(none)" ] && [ -d "$scan" ]; then
            echo "$scan"
            return 0
        fi
    fi
    # Fallbacks: conf.d next to the loaded ini, else php.d (cPanel ea-php)
    if [ -n "${LSO_PHP_INI:-}" ]; then
        local base d
        base="$(dirname "$LSO_PHP_INI")"
        for d in "$base/conf.d" "$base/php.d" "$base/mods-available"; do
            if [ -d "$d" ]; then
                echo "$d"
                return 0
            fi
        done
    fi
    return 1
}

feature_apply_custom_opcache() {
    local ram tier scan_dir
    ram=$(sysinfo_ram_mb)
    tier=$(sysinfo_ram_tier)

    if ! scan_dir=$(_opcache_scan_dir); then
        log_warn "opcache: could not resolve a php.ini scan directory — manual steps:"
        echo "  Create ${OPCACHE_INI_NAME} in your PHP conf.d with:"
        echo "    opcache.memory_consumption=$(lso_opcache_mb "$ram")"
        echo "    opcache.max_accelerated_files=$(_opcache_max_files "$tier")"
        echo "    opcache.interned_strings_buffer=$(_opcache_interned "$tier")"
        echo "    opcache.validate_timestamps=1 / revalidate_freq=60 / save_comments=1"
        return 0
    fi

    # Determine whether the opcache Zend extension is actually loaded. The
    # directives are inert without it — some lsphp builds ship php.ini with
    # `;zend_extension=opcache` commented (or the extension uninstalled). If a
    # matching opcache.so exists in extension_dir but isn't loaded, our drop-in
    # loads it; if the .so is absent entirely, we tune but warn it's a no-op.
    local zend_line="" opcache_loaded="unknown"
    if [ -n "${LSO_PHP_BIN:-}" ] && [ -x "$LSO_PHP_BIN" ] && [ -z "${LSO_FS_ROOT:-}" ]; then
        if "$LSO_PHP_BIN" -m 2>/dev/null | grep -qi '^Zend OPcache$'; then
            opcache_loaded="yes"
        else
            opcache_loaded="no"
            local ext_dir
            ext_dir=$("$LSO_PHP_BIN" -i 2>/dev/null | sed -n 's/^extension_dir => \([^ ]*\).*/\1/p' | head -1)
            if [ -n "$ext_dir" ] && [ -f "${ext_dir}/opcache.so" ]; then
                zend_line="zend_extension=opcache.so"
                log_info "opcache extension present but not loaded — drop-in will load it"
            else
                log_warn "opcache extension (opcache.so) NOT installed for this PHP — directives will be inert"
                log_warn "  Ask the host to install it (e.g. apt install lsphp${LSO_PHP_VER//./}-opcache / php-opcache), then re-run"
            fi
        fi
    fi

    local target="${scan_dir}/${OPCACHE_INI_NAME}"
    template_deploy "${TEMPLATE_DIR}/php/opcache.ini.tpl" "$target" \
        "TIER=${tier}" \
        "ZEND_EXTENSION_LINE=${zend_line}" \
        "MEMORY_MB=$(lso_opcache_mb "$ram")" \
        "INTERNED_MB=$(_opcache_interned "$tier")" \
        "MAX_FILES=$(_opcache_max_files "$tier")" || return 1

    # Detached-PHP restart trigger (lsphp keeps running across lswsctrl restart)
    if [ -n "${LSO_PHP_RESTART:-}" ]; then
        if [ "${DRY_RUN:-false}" = true ]; then
            log_info "[DRY RUN] Would run: ${LSO_PHP_RESTART}"
        elif [ -d "${LSO_LSWS_ROOT:-/nonexistent}/admin/tmp" ]; then
            eval "$LSO_PHP_RESTART" || log_warn "PHP restart trigger failed (non-fatal)"
            log_info "Triggered lsphp restart"
        fi
    fi
}

feature_detect_custom_opcache() {
    local scan_dir
    scan_dir=$(_opcache_scan_dir) || return 1
    [ -f "${scan_dir}/${OPCACHE_INI_NAME}" ]
}

FEATURE_ID="opcache"
FEATURE_DISPLAY="PHP OPcache Tuning"
FEATURE_DETECT_PATTERN="opcache.memory_consumption"
FEATURE_SCOPE="global"
FEATURE_ALIASES="php"
feature_register
