#!/bin/bash
################################################################################
# quic-assist.sh - QUIC.cloud onboarding ASSIST (LIVE-phase Item 5, read-only)
################################################################################
# `litespeed-optimizer quic-assist [--site <dir|url>]` — a READ-ONLY preflight +
# guidance flow for putting a WordPress-on-OpenLiteSpeed store behind QUIC.cloud.
# It NEVER touches DNS and NEVER writes config: it validates cache/Woo correctness,
# BLOCKS if the scored `analyze` audit reports open danger findings, then prints the
# exact CNAME / nameserver target (read back from LSCWP) and STOPS.
#
# Why block-first: flipping DNS to the CDN before the origin's cache rules are
# correct is the top risk — a server-wide cache-everything rule or a cart cookie
# wrongly in Do-Not-Cache can serve one shopper's cart to another once the CDN
# fronts the site. So we refuse to hand out the DNS target until the origin is clean.
#
# NOT automatable (printed as manual steps): QUIC.cloud account/ToS, the Domain Key
# handshake, dashboard CDN settings, and the registrar DNS change. Activation is
# parked on the operator's QUIC.cloud account + DNS change (task #267).
################################################################################

# Read one LSCWP option for a docroot (empty string if wp-cli/option unavailable).
_qc_opt() {
    local docroot="$1" key="$2" v
    v=$(lso_wp "$docroot" litespeed-option get "$key" 2>/dev/null | tr -d '\r') || v=""
    printf '%s' "$v"
}

run_quic_assist() {
    if ! detect_environment; then
        log_error "quic-assist: no LiteSpeed installation found — nothing to onboard"
        exit 1
    fi

    # Resolve the single docroot this assist targets (honour --site; else first site).
    local docroot=""
    if [ -n "${LSO_WP_SITES+x}" ] && [ "${#LSO_WP_SITES[@]}" -gt 0 ]; then
        if ! docroot=$(_resolve_target_docroot "${TARGET_SITE:-}"); then
            [ -n "${TARGET_SITE:-}" ] && log_warn "quic-assist: target '${TARGET_SITE}' matched no detected site — using ${LSO_WP_SITES[0]}"
            docroot="${LSO_WP_SITES[0]}"
        fi
    fi
    if [ -z "$docroot" ]; then
        log_error "quic-assist: no WordPress site detected — cannot preflight"
        return 1
    fi

    if ! _lscwp_have_wpcli; then
        log_error "quic-assist: wp-cli not available — the preflight reads LSCWP options via wp-cli."
        log_error "  Install wp-cli (or set LSO_WP_BIN), then re-run: litespeed-optimizer quic-assist"
        return 1
    fi

    echo ""
    echo "=== litespeed-optimizer quic-assist: ${docroot} (${LSO_EDITION}) ==="
    echo ""

    local blocked=0

    # 1. LSCWP must be active — QUIC.cloud onboarding is driven through it.
    if lso_wp "$docroot" plugin is-active litespeed-cache >/dev/null 2>&1; then
        log_success "preflight: LiteSpeed Cache plugin is active"
    else
        log_error "preflight: LiteSpeed Cache plugin is NOT active — install/activate it and run 'optimize' first"
        blocked=1
    fi

    # 2. WooCommerce presence (informational — the cart-cookie correctness below is
    #    what matters when a store goes behind a CDN).
    local is_woo="no"
    if lso_wp "$docroot" plugin is-active woocommerce >/dev/null 2>&1; then
        is_woo="yes"
        log_info "preflight: WooCommerce detected — cart/checkout cache correctness is critical behind a CDN"
    fi

    # 3. Cart/session-cookie cache exclusion correctness. lscwp_check_vary_cookies
    #    returns 1 (and logs its own DANGER) if woocommerce_items_in_cart is wrongly
    #    in Do-Not-Cache Cookies (LSCWP already varies on it; excluding it kills the
    #    cache for every cart holder). This MUST be clean before the CDN fronts it.
    if lscwp_check_vary_cookies "$docroot"; then
        log_success "preflight: cart cookie is correctly cached-with-vary (not wrongly excluded)"
    else
        blocked=1
    fi

    # 4. Crawler / role simulation (warm-cache-for-roles). Not a hard block, but a
    #    cold cache behind a CDN means slow first hits for real shoppers.
    local crawler
    crawler=$(_qc_opt "$docroot" crawler)
    if [ "$crawler" = "1" ]; then
        log_success "preflight: LSCWP crawler is enabled (cache stays warm for guest/role views)"
    else
        log_warn "preflight: LSCWP crawler is off — enable it so the cache is warm before you point DNS at the CDN"
    fi

    # 5. Scored-audit danger gate. Reuse the LOCAL `analyze`: it returns non-zero when
    #    any open danger finding exists in the origin's config — server-wide
    #    cache-everything (enableCache 1), a disabled vhost rewrite, LSCWP debug on, or
    #    the cart cookie in Do-Not-Cache. Run it quietly; on a block point the operator
    #    at `analyze` for the detail. (Edge-side dangers like a Cloudflare
    #    cache-everything rule are NOT visible to the local audit — they are caught by
    #    `analyze --remote <url>` AFTER cutover, flagged in the post-switch guidance below.)
    if ( JSON_OUTPUT=true run_analyze "$docroot" >/dev/null 2>&1 ); then
        log_success "preflight: scored audit reports no open danger findings"
    else
        log_error "preflight: local 'analyze' reports open DANGER findings (or could not complete) — resolve them first."
        log_error "  Run: litespeed-optimizer analyze${TARGET_SITE:+ \"$TARGET_SITE\"}   (a server-wide cache-everything rule"
        log_error "  or a cart-cache leak must be fixed before the CDN fronts the origin)."
        blocked=1
    fi

    if [ "$blocked" -ne 0 ]; then
        echo ""
        log_error "quic-assist: PREFLIGHT FAILED — do NOT point DNS at QUIC.cloud yet."
        log_error "  Fix the blocker(s) above, re-run quic-assist, and only switch DNS once it passes clean."
        return 1
    fi

    # All clear — surface the exact DNS target QUIC.cloud expects, then STOP.
    local qc_cname qc_ns qc_cdn
    qc_cname=$(_qc_opt "$docroot" qc-cname)
    qc_ns=$(_qc_opt "$docroot" qc-nameservers)
    qc_cdn=$(_qc_opt "$docroot" cdn-quic)

    echo ""
    log_success "quic-assist: origin preflight PASSED — safe to onboard once your QUIC.cloud account is linked."
    echo ""

    if [ -n "$qc_cname" ] || [ -n "$qc_ns" ]; then
        log_info "DNS target (from LSCWP — set this at your registrar YOURSELF; this tool never changes DNS):"
        [ -n "$qc_cname" ] && log_info "  CNAME       -> ${qc_cname}"
        [ -n "$qc_ns" ]    && log_info "  Nameservers -> ${qc_ns}"
    else
        log_warn "DNS target not available yet — this domain is not linked to QUIC.cloud."
        log_info "  Link it first: LiteSpeed Cache > CDN > QUIC.cloud CDN > 'Link to QUIC.cloud' (needs a QUIC.cloud account),"
        log_info "  approve the Domain Key, then re-run 'quic-assist' to read the exact CNAME/nameserver target."
    fi
    [ "$qc_cdn" = "1" ] && log_info "  (LSCWP 'QUIC.cloud CDN' toggle is already ON.)"

    echo ""
    log_info "Before AND after the DNS switch — do NOT skip:"
    log_info "  - keep the origin reachable during propagation (do not firewall it off);"
    log_info "  - verify the origin still serves the correct Set-Cookie through the CDN (cart/session survive);"
    log_info "  - keep payment webhooks reachable through the CDN — Stripe/PayPal/Mollie IPN callbacks must not be"
    log_info "    cached or CAPTCHA-walled, or order completion silently breaks;"
    [ "$is_woo" = "yes" ] && log_info "  - smoke-test cart -> checkout -> order-received AFTER cutover (a cached checkout is the top failure)."
    log_info "  - re-run 'litespeed-optimizer analyze --remote <url>' against the live CDN URL to confirm no cart/HTML"
    log_info "    cache-everything leaked through the edge."

    return 0
}
