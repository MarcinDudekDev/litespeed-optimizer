#!/bin/bash
# shellcheck disable=SC2034  # FEATURE_* vars are consumed by lib/registry.sh feature_register
################################################################################
# features/lscache.sh - Server-Level LSCache Safety Config (SPEC §6 lscache)
################################################################################
# Phase 2 scope: the SERVER-LEVEL cache module block on OLS only.
#
# DANGER GUARD: NEVER `enableCache 1` server-wide — it caches every vhost's
# responses regardless of cookies/sessions (cart/checkout poisoning). LSCWP
# drives caching per-request via X-LiteSpeed-Cache-Control headers; the server
# block only needs checkPublicCache 1 + ignoreRespCacheCtrl 0.
#
# Per-vhost cache config (storagePath $VH_ROOT/lscache) and the LSWS
# CacheRoot/CacheEngine includes ship in Phase 3.
################################################################################

feature_apply_custom_lscache() {
    local conf="${LSO_MAIN_CONF:-}"

    if [ "${LSO_EDITION:-}" = "enterprise" ]; then
        log_warn "LSWS Enterprise: global CacheRoot/CacheEngine includes ship in Phase 3 — recommended:"
        echo "  <IfModule Litespeed>"
        echo "    CacheRoot /home/lscache/"
        echo "    CacheEngine on esi crawler"
        echo "  </IfModule>"
        echo "  Plus per-site .htaccess: CacheLookup public on"
        return 0
    fi

    if [ -z "$conf" ] || [ ! -f "$conf" ]; then
        log_error "lscache: main config not found"
        return 1
    fi

    local block="module cache"
    lso_conf_set "$conf" "$block" internal 1
    lso_conf_set "$conf" "$block" checkPublicCache 1
    lso_conf_set "$conf" "$block" enableCache 0
    lso_conf_set "$conf" "$block" enablePrivateCache 0
    lso_conf_set "$conf" "$block" ignoreRespCacheCtrl 0
    lso_conf_set "$conf" "$block" maxCacheObjSize 10000000
    lso_conf_set "$conf" "$block" maxStaleAge 200

    # Danger guard: re-read and hard-fail if server-level cache ever ends up on
    if [ "${DRY_RUN:-false}" != true ]; then
        if ! lscache_assert_server_cache_off "$conf"; then
            log_error "lscache: enableCache != 0 at server level after apply — aborting"
            return 1
        fi
    fi
}

# lscache_assert_server_cache_off <conf>
# Returns 0 iff the server-level cache module has enableCache 0.
lscache_assert_server_cache_off() {
    local conf="$1"
    local val
    val=$(ols_get "$conf" "module cache" enableCache 2>/dev/null) || return 1
    [ "$val" = "0" ]
}

feature_detect_custom_lscache() {
    local config_file="${1:-${LSO_MAIN_CONF:-}}"
    [ -f "$config_file" ] || return 1

    local val
    val=$(ols_get "$config_file" "module cache" checkPublicCache 2>/dev/null) || return 1
    [ "$val" = "1" ] || return 1
    lscache_assert_server_cache_off "$config_file"
}

FEATURE_ID="lscache"
FEATURE_DISPLAY="LSCache Server-Level Config"
FEATURE_DETECT_PATTERN="checkPublicCache"
FEATURE_SCOPE="global"
FEATURE_ALIASES="cache"
feature_register
