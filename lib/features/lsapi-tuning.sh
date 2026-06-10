#!/bin/bash
# shellcheck disable=SC2034  # FEATURE_* vars are consumed by lib/registry.sh feature_register
################################################################################
# features/lsapi-tuning.sh - LSAPI External App Tuning (SPEC §6 lsapi-tuning)
################################################################################
# THE invariant: maxConns == PHP_LSAPI_CHILDREN. When maxConns < CHILDREN the
# server queues requests it could serve; when maxConns > CHILDREN LSAPI forks
# beyond the plan and the RAM budget breaks. lsapi_assert_invariant() enforces
# this after every apply and is exercised by the golden tests.
#
# OLS:  ols_set / ols_set_env on the `extprocessor lsphp` block in main config.
# LSWS: marker-delimited <IfModule LiteSpeed> block in the Apache include
#       (cPanel) with LSPHP_Workers; report-only when no include path exists.
################################################################################

# Per-tier memory limits for the lsphp external app
_lsapi_mem_soft() {
    case "$1" in
        1g) echo 750M ;;
        2g) echo 1400M ;;
        4g) echo 2000M ;;
        *)  echo 2047M ;;
    esac
}

_lsapi_mem_hard() {
    case "$1" in
        1g) echo 800M ;;
        2g) echo 1500M ;;
        *)  echo 2047M ;;
    esac
}

# Compute children for the current system (measured RSS wins over default)
_lsapi_children() {
    local ram cores rss
    ram=$(sysinfo_ram_mb)
    cores=$(sysinfo_cpu_cores)
    rss=$(sysinfo_lsphp_rss)
    lso_children "$ram" "$cores" "${rss:-80}"
}

feature_apply_custom_lsapi_tuning() {
    local ram tier conf children
    ram=$(sysinfo_ram_mb)
    tier=$(sysinfo_ram_tier)
    conf="${LSO_MAIN_CONF:-}"
    children=$(_lsapi_children)

    log_info "LSAPI sizing: children=${children} (RAM budget: $(lso_ram_budget_check "$ram" "$(sysinfo_cpu_cores)"))"

    if [ "${LSO_EDITION:-}" = "enterprise" ]; then
        _lsapi_apply_enterprise "$children"
        return $?
    fi

    if [ -z "$conf" ] || [ ! -f "$conf" ]; then
        log_error "lsapi-tuning: main config not found"
        return 1
    fi

    local block="extprocessor lsphp"

    # The invariant pair — always written together
    lso_conf_set "$conf" "$block" maxConns "$children"
    lso_conf_set_env "$conf" "$block" PHP_LSAPI_CHILDREN "$children"

    lso_conf_set_env "$conf" "$block" LSAPI_AVOID_FORK "$(lso_avoid_fork "$ram")"
    lso_conf_set_env "$conf" "$block" LSAPI_MAX_REQS 10000
    lso_conf_set_env "$conf" "$block" LSAPI_MAX_IDLE 3600
    lso_conf_set_env "$conf" "$block" LSAPI_ACCEPT_NOTIFY 1
    lso_conf_set_env "$conf" "$block" LSAPI_SLOW_REQ_MSECS 5000
    if [ "$tier" != "1g" ]; then
        lso_conf_set_env "$conf" "$block" LSAPI_PGRP_MAX_IDLE 3600
    fi

    lso_conf_set "$conf" "$block" memSoftLimit "$(_lsapi_mem_soft "$tier")"
    lso_conf_set "$conf" "$block" memHardLimit "$(_lsapi_mem_hard "$tier")"

    # Post-write invariant check (skipped in dry-run — nothing was written)
    if [ "${DRY_RUN:-false}" != true ]; then
        if ! lsapi_assert_invariant "$conf"; then
            log_error "lsapi-tuning: maxConns != PHP_LSAPI_CHILDREN after apply — aborting"
            return 1
        fi
    fi
}

# Enterprise path: <IfModule LiteSpeed> via Apache include (cPanel), else report
_lsapi_apply_enterprise() {
    local children="$1"
    local include="${LSO_APACHE_INCLUDE:-}"

    if [ -z "$include" ]; then
        log_warn "LSWS Enterprise without Apache include path — manual steps:"
        echo "  Add to your Apache config (or pre_main_global.conf):"
        echo "    <IfModule LiteSpeed>"
        echo "      LSPHP_Workers ${children}"
        echo "    </IfModule>"
        echo "  Note: suEXEC daemon mode recommended; verify in WHM > LiteSpeed config."
        return 0
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would write LSPHP_Workers ${children} block to ${include}"
        return 0
    fi

    mkdir -p "$(dirname "$include")"
    touch "$include"

    # Idempotent replace of our marker-delimited block
    local tmp
    tmp=$(secure_mktemp "$(dirname "$include")/.lso-inc.XXXXXX") || return 1
    awk '
        /^# BEGIN litespeed-optimizer lsapi/ { skip = 1; next }
        /^# END litespeed-optimizer lsapi/ { skip = 0; next }
        !skip { print }
    ' "$include" > "$tmp"
    {
        echo "# BEGIN litespeed-optimizer lsapi"
        echo "<IfModule LiteSpeed>"
        echo "  LSPHP_Workers ${children}"
        echo "</IfModule>"
        echo "# END litespeed-optimizer lsapi"
    } >> "$tmp"
    copy_file_permissions "$include" "$tmp" 2>/dev/null || true
    mv "$tmp" "$include"
    log_info "Wrote LSPHP_Workers ${children} to ${include} (suEXEC note: verify daemon mode in WHM)"
}

# lsapi_assert_invariant <conf-file>
# Returns 0 iff maxConns == PHP_LSAPI_CHILDREN in the lsphp extprocessor.
lsapi_assert_invariant() {
    local conf="$1"
    local maxconns children
    maxconns=$(ols_get "$conf" "extprocessor lsphp" maxConns 2>/dev/null) || return 1
    children=$(ols_get_env "$conf" "extprocessor lsphp" PHP_LSAPI_CHILDREN 2>/dev/null) || return 1
    [ -n "$maxconns" ] && [ "$maxconns" = "$children" ]
}

feature_detect_custom_lsapi_tuning() {
    local config_file="${1:-${LSO_MAIN_CONF:-}}"
    [ -f "$config_file" ] || return 1

    # Applied = ACCEPT_NOTIFY marker present AND invariant holds
    ols_get_env "$config_file" "extprocessor lsphp" LSAPI_ACCEPT_NOTIFY >/dev/null 2>&1 || return 1
    lsapi_assert_invariant "$config_file"
}

FEATURE_ID="lsapi-tuning"
FEATURE_DISPLAY="LSAPI PHP Tuning (extprocessor)"
FEATURE_DETECT_PATTERN="LSAPI_ACCEPT_NOTIFY"
FEATURE_SCOPE="global"
FEATURE_ALIASES="lsapi,php-workers"
feature_register
