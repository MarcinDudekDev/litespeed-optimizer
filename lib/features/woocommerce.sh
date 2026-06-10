#!/bin/bash
# shellcheck disable=SC2034  # FEATURE_* vars are consumed by lib/registry.sh feature_register
################################################################################
# features/woocommerce.sh - WooCommerce-Specific Cache Setup (SPEC §6)
################################################################################
# Depends on lscwp (sourced earlier; provides lso_wp + vary checks).
#
# ESI policy: Enterprise gets ESI (mini-cart/admin-bar/comment-form hole
# punching). OLS has NO ESI engine — warn, suggest QUIC.cloud, and rely on
# LSCWP's built-in vary-on-cart-cookie behavior instead.
#
# Crawler: enabled with sitemap autodetect, load limit 1.0, role simulation
# OFF (CVE-2024-28000 attack surface).
################################################################################

_woo_site_has_woo() {
    local docroot="$1"
    lso_wp "$docroot" plugin is-active woocommerce >/dev/null 2>&1
}

# Set one LSCWP option (dry-run aware) — thin wrapper used repeatedly here
_woo_set_opt() {
    local docroot="$1" key="$2" value="$3"
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would set LSCWP option: ${key} = ${value}"
        return 0
    fi
    if lso_wp "$docroot" litespeed-option set "$key" "$value" >/dev/null 2>&1; then
        log_info "LSCWP: ${key} = ${value}"
    else
        log_warn "LSCWP: failed to set ${key}"
    fi
}

_woo_apply_site() {
    local docroot="$1"

    if ! _woo_site_has_woo "$docroot"; then
        log_info "WooCommerce not active on ${docroot} — skipping"
        return 0
    fi

    log_info "WooCommerce: processing ${docroot}"

    # 1. ESI — Enterprise only
    if [ "${LSO_EDITION:-}" = "enterprise" ]; then
        _woo_set_opt "$docroot" esi 1
        _woo_set_opt "$docroot" esi-cache_admbar 1
        _woo_set_opt "$docroot" esi-cache_commform 1
        log_info "ESI enabled (requires 'CacheEngine on esi' server-side — lscache feature)"
    else
        log_warn "OpenLiteSpeed has NO ESI engine — mini-cart hole punching unavailable"
        log_warn "  Options: (a) QUIC.cloud CDN provides ESI, (b) rely on LSCWP cart-cookie vary (default),"
        log_warn "  (c) if the theme shows a stale mini-cart, enable 'Vary for Mini Cart' in LSCWP"
        _woo_set_opt "$docroot" esi 0
    fi

    # 2. Crawler: warm the cache; role simulation stays OFF (CVE surface)
    _woo_set_opt "$docroot" crawler 1
    _woo_set_opt "$docroot" crawler-load_limit 1
    _woo_set_opt "$docroot" crawler-role_sims ""
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would run: wp litespeed-crawler enable"
    else
        lso_wp "$docroot" litespeed-crawler enable >/dev/null 2>&1 || true
        log_info "Crawler enabled (first warm-up: wp litespeed-crawler run)"
    fi

    # 3. Cache-vary sanity checks
    lscwp_check_vary_cookies "$docroot" || true

    # Multi-currency: currency switchers need their cookie in Vary Cookies
    local mc_plugin=""
    if lso_wp "$docroot" plugin is-active woocommerce-currency-switcher >/dev/null 2>&1; then
        mc_plugin="woocommerce-currency-switcher"
    elif lso_wp "$docroot" plugin is-active woocommerce-multilingual >/dev/null 2>&1; then
        mc_plugin="woocommerce-multilingual"
    fi
    if [ -n "$mc_plugin" ]; then
        local vary
        vary=$(lso_wp "$docroot" litespeed-option get cache-vary_cookies 2>/dev/null) || vary=""
        if ! echo "$vary" | grep -qi "currency\|wcml"; then
            log_warn "Multi-currency plugin (${mc_plugin}) active but no currency cookie in Vary Cookies"
            log_warn "  Cached pages will show the wrong currency. Add the switcher's cookie via:"
            log_warn "  LiteSpeed Cache > Cache > Vary Cookies (e.g. 'wcml_currency' or the plugin's cookie)"
        fi
    fi

    # 4. Purge after config changes
    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would run: wp litespeed-purge all"
    else
        lso_wp "$docroot" litespeed-purge all >/dev/null 2>&1 || true
    fi
}

feature_apply_custom_woocommerce() {
    local target_site="${1:-}"

    if ! _lscwp_have_wpcli; then
        log_warn "wp-cli not found — skipping WooCommerce cache setup"
        return 0
    fi

    if [ -z "${LSO_WP_SITES+x}" ] || [ "${#LSO_WP_SITES[@]}" -eq 0 ]; then
        log_warn "No WordPress sites found — nothing for WooCommerce setup"
        return 0
    fi

    local docroot rc=0
    for docroot in "${LSO_WP_SITES[@]}"; do
        if [ -n "$target_site" ] && [[ "$docroot" != *"$target_site"* ]]; then
            continue
        fi
        _woo_apply_site "$docroot" || rc=1
    done
    return $rc
}

feature_detect_custom_woocommerce() {
    _lscwp_have_wpcli || return 1
    [ -n "${LSO_WP_SITES+x}" ] && [ "${#LSO_WP_SITES[@]}" -gt 0 ] || return 1

    local docroot="${LSO_WP_SITES[0]}"
    _woo_site_has_woo "$docroot" || return 1
    local crawler
    crawler=$(lso_wp "$docroot" litespeed-option get crawler 2>/dev/null) || return 1
    [ "$crawler" = "1" ]
}

FEATURE_ID="woocommerce"
FEATURE_DISPLAY="WooCommerce Cache Setup (ESI/crawler)"
FEATURE_DETECT_PATTERN="woocommerce"
FEATURE_SCOPE="per-site"
FEATURE_ALIASES="woo"
feature_register
