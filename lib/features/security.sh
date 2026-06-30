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

# Deploy safe security response headers via per-site .htaccess (LiteSpeed honors
# mod_headers). Marker-delimited + idempotent. Only headers that never break a
# normal site: nosniff, SAMEORIGIN, Referrer-Policy. HSTS is intentionally NOT
# set here — it needs HTTPS and a deliberate rollout (a wrong max-age locks users
# out), so it stays a documented opt-in rather than an automatic change.
_sec_apply_headers_site() {
    local docroot="$1"
    local htaccess="${docroot%/}/.htaccess"

    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would deploy security headers to ${htaccess}"
        return 0
    fi

    touch "$htaccess" 2>/dev/null || { log_warn "Cannot write ${htaccess} — skipping headers"; return 0; }

    local tmp
    tmp=$(secure_mktemp "${docroot%/}/.lso-hdr.XXXXXX") || return 1
    # Strip any prior block, then append a fresh one (idempotent + updatable).
    awk '
        /^# BEGIN litespeed-optimizer headers/ { skip = 1; next }
        /^# END litespeed-optimizer headers/ { skip = 0; next }
        !skip { print }
    ' "$htaccess" > "$tmp"
    {
        echo "# BEGIN litespeed-optimizer headers"
        echo "<IfModule mod_headers.c>"
        echo "Header set X-Content-Type-Options \"nosniff\""
        echo "Header set X-Frame-Options \"SAMEORIGIN\""
        echo "Header set Referrer-Policy \"strict-origin-when-cross-origin\""
        echo "</IfModule>"
        echo "# END litespeed-optimizer headers"
    } >> "$tmp"
    copy_file_permissions "$htaccess" "$tmp" 2>/dev/null || true
    mv "$tmp" "$htaccess"
    log_info "Deployed security headers to ${htaccess}"
}

_sec_apply_headers() {
    if [ -z "${LSO_WP_SITES+x}" ] || [ "${#LSO_WP_SITES[@]}" -eq 0 ]; then
        log_warn "security headers: no WordPress sites detected — skipping (.htaccess is per-site)"
        return 0
    fi
    local docroot
    for docroot in "${LSO_WP_SITES[@]}"; do
        [ -d "$docroot" ] || continue
        _sec_apply_headers_site "$docroot"
    done
}

# Curated, CONSERVATIVE bad-bot User-Agent denylist. Deliberately excludes every
# major search engine (Googlebot, Bingbot, DuckDuckBot, Applebot, YandexBot,
# Baiduspider) and social unfurlers. It targets aggressive commercial SEO
# scrapers that generate real load, AI training crawlers, and obvious
# vulnerability scanners — the UAs site owners most often want gone. Because the
# whole blocker is OPT-IN (--badbots / LSO_BADBOTS=1), enabling it is a
# deliberate choice. BrowserMatchNoCase matches each token as a case-insensitive
# REGEX against the UA; every entry here is a plain alnum crawler name with no
# regex metacharacters, so each behaves as a simple substring match.
_SEC_BADBOTS="AhrefsBot SemrushBot MJ12bot DotBot BLEXBot PetalBot Bytespider \
DataForSeoBot MegaIndex ZoominfoBot serpstatbot MauiBot magpie-crawler \
GPTBot CCBot ClaudeBot Nikto sqlmap ZmEu WPScan masscan zgrab"

# Deploy a per-site .htaccess bad-bot UA denylist. Same marker-delimited,
# idempotent, atomic pattern as _sec_apply_headers_site. Emits dual authz syntax
# so it works on both Apache 2.4 (mod_authz_core) and 2.2 (mod_access_compat)
# emulation under LiteSpeed.
_sec_apply_badbots_site() {
    local docroot="$1"
    local htaccess="${docroot%/}/.htaccess"

    if [ "${DRY_RUN:-false}" = true ]; then
        log_info "[DRY RUN] Would deploy bad-bot UA blocker to ${htaccess}"
        return 0
    fi

    touch "$htaccess" 2>/dev/null || { log_warn "Cannot write ${htaccess} — skipping bad-bot blocker"; return 0; }

    local tmp
    tmp=$(secure_mktemp "${docroot%/}/.lso-bot.XXXXXX") || return 1
    # Strip any prior block, then append a fresh one (idempotent + updatable).
    awk '
        /^# BEGIN litespeed-optimizer badbots/ { skip = 1; next }
        /^# END litespeed-optimizer badbots/ { skip = 0; next }
        !skip { print }
    ' "$htaccess" > "$tmp"
    {
        echo "# BEGIN litespeed-optimizer badbots"
        echo "<IfModule mod_setenvif.c>"
        local bot
        for bot in $_SEC_BADBOTS; do
            echo "BrowserMatchNoCase \"${bot}\" lso_bad_bot"
        done
        echo "<IfModule mod_authz_core.c>"
        echo "<RequireAll>"
        echo "Require all granted"
        echo "Require not env lso_bad_bot"
        echo "</RequireAll>"
        echo "</IfModule>"
        echo "<IfModule !mod_authz_core.c>"
        echo "Order Allow,Deny"
        echo "Allow from all"
        echo "Deny from env=lso_bad_bot"
        echo "</IfModule>"
        echo "</IfModule>"
        echo "# END litespeed-optimizer badbots"
    } >> "$tmp"
    copy_file_permissions "$htaccess" "$tmp" 2>/dev/null || true
    mv "$tmp" "$htaccess"
    log_info "Deployed bad-bot UA blocker to ${htaccess}"
}

_sec_apply_badbots() {
    if [ -z "${LSO_WP_SITES+x}" ] || [ "${#LSO_WP_SITES[@]}" -eq 0 ]; then
        log_warn "bad-bot blocker: no WordPress sites detected — skipping (.htaccess is per-site)"
        return 0
    fi
    local docroot
    for docroot in "${LSO_WP_SITES[@]}"; do
        [ -d "$docroot" ] || continue
        _sec_apply_badbots_site "$docroot"
    done
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

    # Security response headers (per-site .htaccess) — makes the `headers` alias
    # truthful and satisfies the remote audit's missing-header findings.
    _sec_apply_headers

    # Bad-bot UA blocker (per-site .htaccess) — OPT-IN only (--badbots /
    # LSO_BADBOTS=1). It denies known scrapers/scanners; gating it keeps the
    # default run from surprising anyone whose traffic mix wants those crawlers.
    if [ "${LSO_BADBOTS:-}" = "1" ]; then
        _sec_apply_badbots
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
