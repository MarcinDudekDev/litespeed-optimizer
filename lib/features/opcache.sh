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

# opcache.max_accelerated_files is NOT used as written: PHP rounds it UP to the
# next entry of a fixed prime table before sizing the hash. Measured on PHP
# 8.5.1 via opcache_get_status()['opcache_statistics']['max_cached_keys'] —
# note opcache_get_configuration() lies here, it echoes back the raw ini value:
#
#   1000 -> 1979    8000 -> 16229   20000 -> 32531   50000 -> 65407
#   2000 -> 3907   10000 -> 16229   30000 -> 32531  100000 -> 130987
#   4000 -> 7963   16229 -> 16229   32531 -> 32531
#
# So the old table (1g/2g=20000, 4g=30000, 8g=50000) resolved to 32531/32531/
# 65407 — the 4g tier's apparent +50% over 2g bought exactly zero extra slots.
# Every value below is a real prime-table entry, so the ini now states what PHP
# will actually do, and each tier is a genuine step up from the one below it.
#
# Sizing rationale (SHIFT64 benchmark, see README "Credits & Inspiration"):
# one realistically-equipped WooCommerce store measures 5,168 slots / 98.6MB of
# opcodes / 21.5MB of interned strings — i.e. ~19.5KB of opcode per file. At
# that density a tier's pool (memory_consumption minus the interned buffer) can
# physically hold: 1g ~2.5k files, 2g ~5.4k, 4g/8g ~11.7k. Each tier is given
# ~3x that as headroom, because the two failure modes are wildly asymmetric —
# a spare slot costs ~48 bytes of pool, while running out of slots makes
# OPcache silently stop caching (it has no eviction policy) and recompile
# hundreds of files per request. Oversize deliberately; do not "right-size".
_opcache_max_files() {
    case "$1" in
        1g) echo 7963 ;;
        2g) echo 16229 ;;
        4g) echo 32531 ;;
        *)  echo 65407 ;;
    esac
}

# interned_strings_buffer is carved OUT of memory_consumption, so it cannot be
# oversized as freely as the slot count. One equipped Woo store measures 21.5MB
# of interned strings (SHIFT64), which the old 16MB 2g value could not hold —
# overflow does not error, it just stops interning, and every new string is
# then duplicated into every worker's private memory. 2g therefore gets 24MB.
# 1g stays at 16MB: a 64MB pool cannot spare more, and a 1GB box is not hosting
# an equipped store. 4g/8g keep 32MB, the benchmark's own recommendation.
_opcache_interned() {
    case "$1" in
        1g) echo 16 ;;
        2g) echo 24 ;;
        *)  echo 32 ;;
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

    # Force-recycle lsphp so the new drop-in is live in the web SAPI immediately.
    # A graceful lswsctrl restart leaves existing lsphp children on the OLD config;
    # lso_recycle_lsphp kills them by PID (LSWS respawns on demand). The drop-in is
    # already on disk (template_deploy above), so respawned workers load it.
    # Honors DRY_RUN and fixture/test mode internally.
    lso_recycle_lsphp
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
