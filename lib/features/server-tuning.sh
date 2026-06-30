#!/bin/bash
# shellcheck disable=SC2034  # FEATURE_* vars are consumed by lib/registry.sh feature_register
################################################################################
# features/server-tuning.sh - tuning{} Block (SPEC §6 server-tuning)
################################################################################
# OLS:  ols_set on the main config's tuning{} block (these keys cannot live in
#       include files on all OLS versions, so we edit in place).
# LSWS: report-only in v0.1 — tuning{} is WebAdmin/XML territory; we print the
#       recommended values and never touch the XML.
################################################################################

# Per-tier value helpers (SYNTHESIS §2 ranges)
_st_conn_timeout() {
    case "$1" in
        1g) echo 60 ;;
        2g) echo 45 ;;
        *)  echo 30 ;;
    esac
}

_st_keepalive_timeout() {
    case "$1" in
        1g|2g) echo 5 ;;
        4g)    echo 3 ;;
        *)     echo 2 ;;
    esac
}

_st_brotli_level() {
    case "$1" in
        1g|2g) echo 2 ;;
        4g)    echo 3 ;;
        *)     echo 4 ;;
    esac
}

_st_inmem_cache() {
    case "$1" in
        1g) echo 20M ;;
        2g) echo 40M ;;
        4g) echo 80M ;;
        *)  echo 160M ;;
    esac
}

_st_mmap_cache() {
    case "$1" in
        1g) echo 40M ;;
        2g) echo 80M ;;
        4g) echo 160M ;;
        *)  echo 320M ;;
    esac
}

# Print the recommended values (used for Enterprise report-only and --verbose)
_st_print_recommendations() {
    local ram tier
    ram=$(sysinfo_ram_mb)
    tier=$(sysinfo_ram_tier)
    echo "  Recommended tuning{} values (tier ${tier}):"
    echo "    maxConnections        $(lso_max_connections "$ram")"
    echo "    connTimeout           $(_st_conn_timeout "$tier")"
    echo "    keepAliveTimeout      $(_st_keepalive_timeout "$tier")"
    echo "    maxKeepAliveReq       1000"
    echo "    sndBufSize            0"
    echo "    rcvBufSize            0"
    echo "    enableBr              1"
    echo "    brStaticCompressLevel $(_st_brotli_level "$tier")"
    echo "    gzipAutoUpdateStatic  1"
    echo "    totalInMemCacheSize   $(_st_inmem_cache "$tier")"
    echo "    totalMMapCacheSize    $(_st_mmap_cache "$tier")"
}

feature_apply_custom_server_tuning() {
    local ram tier conf
    ram=$(sysinfo_ram_mb)
    tier=$(sysinfo_ram_tier)
    conf="${LSO_MAIN_CONF:-}"

    if [ "${LSO_EDITION:-}" = "enterprise" ]; then
        log_warn "LSWS Enterprise: tuning{} is managed via WebAdmin/XML — report-only in v0.1"
        _st_print_recommendations
        return 0
    fi

    if [ -z "$conf" ] || [ ! -f "$conf" ]; then
        log_error "server-tuning: main config not found"
        return 1
    fi

    lso_conf_set "$conf" tuning maxConnections "$(lso_max_connections "$ram")"
    lso_conf_set "$conf" tuning connTimeout "$(_st_conn_timeout "$tier")"
    lso_conf_set "$conf" tuning keepAliveTimeout "$(_st_keepalive_timeout "$tier")"
    lso_conf_set "$conf" tuning maxKeepAliveReq 1000
    lso_conf_set "$conf" tuning sndBufSize 0
    lso_conf_set "$conf" tuning rcvBufSize 0
    lso_conf_set "$conf" tuning enableGzipCompress 1
    lso_conf_set "$conf" tuning enableDynGzipCompress 1
    lso_conf_set "$conf" tuning gzipCompressLevel 6
    lso_conf_set "$conf" tuning enableBr 1
    lso_conf_set "$conf" tuning brStaticCompressLevel "$(_st_brotli_level "$tier")"
    lso_conf_set "$conf" tuning gzipAutoUpdateStatic 1
    lso_conf_set "$conf" tuning maxCachedFileSize 4096
    lso_conf_set "$conf" tuning totalInMemCacheSize "$(_st_inmem_cache "$tier")"
    lso_conf_set "$conf" tuning maxMMapFileSize 256K
    lso_conf_set "$conf" tuning totalMMapCacheSize "$(_st_mmap_cache "$tier")"
    lso_conf_set "$conf" tuning useSendfile 1
}

feature_detect_custom_server_tuning() {
    local config_file="${1:-${LSO_MAIN_CONF:-}}"
    [ -f "$config_file" ] || return 1

    # On LSWS Enterprise the config is XML, not the flat OLS key/value format that
    # ols_get parses — running the line parser there yields a false "not applied".
    # The apply path is report-only on Enterprise (tuning{} is WebAdmin/XML-managed),
    # so detection cannot meaningfully report "applied" either; treat as not-applied.
    if [ "${LSO_EDITION:-}" = "enterprise" ]; then
        return 1
    fi

    # Applied = our marker key present AND maxConnections at the tier value
    local ram want got
    ram=$(sysinfo_ram_mb)
    want=$(lso_max_connections "$ram")
    got=$(ols_get "$config_file" tuning maxConnections 2>/dev/null) || return 1
    [ "$got" = "$want" ] || return 1
    got=$(ols_get "$config_file" tuning gzipAutoUpdateStatic 2>/dev/null) || return 1
    [ "$got" = "1" ]
}

FEATURE_ID="server-tuning"
FEATURE_DISPLAY="Server Tuning (tuning{} block)"
FEATURE_DETECT_PATTERN="gzipAutoUpdateStatic[[:space:]]+1"
FEATURE_SCOPE="global"
FEATURE_ALIASES="tuning"
feature_register
