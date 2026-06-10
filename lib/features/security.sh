#!/bin/bash
# shellcheck disable=SC2034  # FEATURE_* vars are consumed by lib/registry.sh feature_register
################################################################################
# features/security.sh - Per-Client Throttling + Hardening (SPEC §6 security)
################################################################################
# OLS:  perClientConnLimit block in main config (SYNTHESIS §6 values).
#       Caveat: NAT'd offices can trip dynReqPerSec 2 — --trusted-ip support
#       is a v0.2 item; values are conservative-but-sane defaults.
# LSWS: WordPressProtect via Apache include (brute-force drop after 10 tries).
# reCAPTCHA: report-only (needs user keys). ModSecurity: detect+report only
#       (OLS supports ModSec 3.x ONLY; CRS false-positive risk on checkout).
################################################################################

_sec_apply_ols_throttling() {
    local conf="$1"
    local block="perClientConnLimit"

    lso_conf_set "$conf" "$block" dynReqPerSec 2
    lso_conf_set "$conf" "$block" staticReqPerSec 40
    lso_conf_set "$conf" "$block" softLimit 15
    lso_conf_set "$conf" "$block" hardLimit 20
    lso_conf_set "$conf" "$block" gracePeriod 15
    lso_conf_set "$conf" "$block" banPeriod 300
    lso_conf_set "$conf" "$block" blockBadReq 1
}

_sec_apply_enterprise() {
    local include="${LSO_APACHE_INCLUDE:-}"

    if [ -z "$include" ]; then
        log_warn "Enterprise without Apache include path — add manually:"
        echo "  <IfModule LiteSpeed>"
        echo "    WordPressProtect drop, 10"
        echo "  </IfModule>"
        return 0
    fi

    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would write WordPressProtect block to ${include}"
        return 0
    fi

    mkdir -p "$(dirname "$include")"
    touch "$include"

    local tmp
    tmp=$(secure_mktemp "$(dirname "$include")/.lso-inc.XXXXXX") || return 1
    awk '
        /^# BEGIN litespeed-optimizer security/ { skip = 1; next }
        /^# END litespeed-optimizer security/ { skip = 0; next }
        !skip { print }
    ' "$include" > "$tmp"
    {
        echo "# BEGIN litespeed-optimizer security"
        echo "<IfModule LiteSpeed>"
        echo "  WordPressProtect drop, 10"
        echo "</IfModule>"
        echo "# END litespeed-optimizer security"
    } >> "$tmp"
    copy_file_permissions "$include" "$tmp" 2>/dev/null || true
    mv "$tmp" "$include"
    log_info "Wrote WordPressProtect drop,10 to ${include}"
    log_info "Throttling on Enterprise: set per-client limits in WHM > LiteSpeed WebAdmin (XML is read-only for this tool)"
}

_sec_report_recaptcha() {
    log_info "reCAPTCHA protection: report-only (requires your site keys)"
    echo "  To enable: WebAdmin > Security > CAPTCHA (lsrecaptcha)"
    echo "  Recommended: Connection Limit slightly above normal peak so it actually triggers;"
    echo "  keep Bot White List for Googlebot. Provide keys, then re-run with v0.2 --recaptcha."
}

_sec_report_modsec() {
    local modsec_found=false
    if [ -f "${LSO_LSWS_ROOT}/modules/mod_security.so" ] || \
       grep -q "module mod_security" "${LSO_MAIN_CONF:-/dev/null}" 2>/dev/null; then
        modsec_found=true
    fi

    if [ "$modsec_found" = true ]; then
        log_info "ModSecurity module detected — verify OWASP CRS rules load (report-only in v0.1)"
    else
        if [ "${LSO_EDITION:-}" = "ols" ]; then
            log_info "ModSecurity: not detected. NOTE: OLS supports ModSecurity 3.x ONLY (libmodsecurity),"
            log_info "  not 2.9 syntax. OWASP CRS has false-positive risk on Woo AJAX/checkout — v0.2 item."
        else
            log_info "ModSecurity: not detected. Enterprise supports async 2.9-syntax engine — v0.2 item."
        fi
    fi
}

feature_apply_custom_security() {
    if [ "${LSO_EDITION:-}" = "enterprise" ]; then
        _sec_apply_enterprise
    else
        local conf="${LSO_MAIN_CONF:-}"
        if [ -z "$conf" ] || [ ! -f "$conf" ]; then
            log_error "security: main config not found"
            return 1
        fi
        _sec_apply_ols_throttling "$conf"
    fi

    _sec_report_recaptcha
    _sec_report_modsec
}

feature_detect_custom_security() {
    local config_file="${1:-${LSO_MAIN_CONF:-}}"

    if [ "${LSO_EDITION:-}" = "enterprise" ]; then
        [ -n "${LSO_APACHE_INCLUDE:-}" ] && grep -q "WordPressProtect" "${LSO_APACHE_INCLUDE}" 2>/dev/null
        return $?
    fi

    [ -f "$config_file" ] || return 1
    local v
    v=$(ols_get "$config_file" perClientConnLimit blockBadReq 2>/dev/null) || return 1
    [ "$v" = "1" ] || return 1
    v=$(ols_get "$config_file" perClientConnLimit dynReqPerSec 2>/dev/null) || return 1
    [ -n "$v" ] && [ "$v" -ge 1 ] && [ "$v" -le 5 ]
}

FEATURE_ID="security"
FEATURE_DISPLAY="Security (throttling/WordPressProtect)"
FEATURE_DETECT_PATTERN="blockBadReq"
FEATURE_SCOPE="global"
FEATURE_ALIASES="headers,throttling"
feature_register
